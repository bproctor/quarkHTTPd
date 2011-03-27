module quarkhttp.thread;

import core.thread;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.regex;
import std.socket;
import std.stdio;
import std.string;
import std.uri;
import quarkhttp.core;
import quarkhttp.utils;


class QuarkThread: Thread
{
private:
    Socket client;
    string root;


    void sendResponse(in ResponseStatus status,
                      lazy const void[] message_body = null,
                      in string content_type = "text/html")
    {
        string status_line = format(HTTP_VERSION_1_1 ~ " %s %s" ~ CRLF,
            to!string(status.code), std.uri.encode(status.reason));

        string headers;

        if (content_type && content_type != "")
            headers ~= "Content-Type: " ~ std.uri.encode(content_type) ~ CRLF;

        headers ~= "Content-Length: " ~ to!string(message_body.length) ~ CRLF;

        string response = status_line ~ headers ~ CRLF;
        client.send(response);

        if (message_body)
            client.send(message_body);
    }


    void sendErrorPage(in ResponseStatus status, in string message)
    {
        auto message_body = format("<h2>%d %s</h2><hr>%s", status.code, message, BANNER);
        sendResponse(status, cast(void[])message_body);
    }


    /* Receives, parses and returns HTTP request line with decoded URI.
     */
    RequestLine receiveRequestLine()
    {
        auto line = receiveLine();
        auto format_match = std.regex.match(line, regex(`(\w+) ([^ ]+) ([^ ]+)`));

        if (line != format_match.hit())
            throw new Exception("Invalid request line format: " ~ line);

        if (format_match.captures[3] != HTTP_VERSION_1_1)
            throw new Exception("Invalid protocol version: " ~ format_match.captures[3]);

        const RequestMethod[string] methods =
        [
            "OPTIONS": RequestMethod.OPTIONS,
            "GET": RequestMethod.GET,
            "HEAD": RequestMethod.HEAD,
            "POST": RequestMethod.POST,
            "PUT": RequestMethod.PUT,
            "DELETE": RequestMethod.DELETE,
            "TRACE": RequestMethod.TRACE,
            "CONNECT": RequestMethod.CONNECT
        ];

        auto method = methods.get(format_match.captures[1], RequestMethod.UNKNOWN);
        auto uri = std.uri.decodeComponent(format_match.captures[2]);

        writeln("REQUEST ", line);

        return RequestLine(method, uri);
    }
    

    /* Receives and returns HTTP headers.
     */
    Header[] receiveHeaders()
    {
        Header[] headers;
        
        for (string line = receiveLine(); !line.empty; line = receiveLine())
        {
            if (iswhite(line[0]))
            {
                if (headers.empty)
                    throw new Exception("Header starting from whitespace is invalid: `" ~ line ~ "'");

                headers.back.value ~= strip(line);
            }
            else
            {
                auto format_match = match(line, regex(`([^ ]+):(.+)`));

                if (line != format_match.hit())
                    throw new Exception("Invalid header format: `" ~ line ~ "'");

                with (format_match)
                    headers ~= Header(captures[1], strip(captures[2]));
            }
        }

        return headers;
    }

    
    /* Receives a line from client, line ending is CRLF.
     * Throws an exception if line ending was not received
     */
    string receiveLine()
    {
        string line;
        char[1] buffer, previous;
        bool received_crlf;

        /* Possible optimization (part 1)
         * line.reserve(16);
         */
        
        while (client.receive(buffer))
        {
            if (previous == "\r" && buffer == "\n")
            {
                received_crlf = true;
                --line.length;
                break;
            }

            /* Possible optimization (part 2)
             * if (line.length == line.capacity)
             *   line.reserve(line.capacity * 2);
             */

            line ~= buffer;
            previous = buffer;
        }

        if (!received_crlf)
            throw new Exception("Did not receive line ending");

        return line;
    }

    
    void[] receiveMessageBody()
    {
        byte[] message_body;
        byte[16] buffer;

        for (auto received = client.receive(buffer); received; received = client.receive(buffer))
        {
            auto from = message_body.length - 1, to = from + received;
            message_body.length += received;
            message_body[from .. to] = buffer[0 .. received];
        }

        return message_body;
    }


    alias bool delegate(in RequestLine request, in Header[] headers) RequestHandler;


    bool processRequest(in RequestLine request, in Header[] headers, in RequestHandler[] handlers)
    {
        foreach (handle; handlers)
        {
            if (handle(request, headers))
                return true;
        }

        return false;
    }


    void run()
    {
        scope (exit)
        {
            client.shutdown(SocketShutdown.BOTH);
            client.close();
        }

        try
        {
            auto request_line = receiveRequestLine();
            
            if (request_line.method != RequestMethod.GET)
            {
                sendErrorPage(STATUS_NOT_IMPLEMENTED, "Unknown request method");
                return;
            }

            auto headers = receiveHeaders();

            if (!processRequest(request_line, headers,
                [
                    &getOrdinaryFile,
                    &getIndex,
                    &getDirListing
                ]))
            {
                sendErrorPage(STATUS_NOT_IMPLEMENTED, "Not implemented");
                return;
            }
        }
        catch (Throwable exception)
        {
            sendErrorPage(STATUS_INTERNAL_ERROR, "Internal server error");
            return;
        }
    }


    //----- HANDLERS -----//
    

    bool getOrdinaryFile(in RequestLine request, in Header[] headers)
    {
        return sendFile(std.path.join(root, request.uri.skip("/")));
    }


    bool getIndex(in RequestLine request, in Header[] headers)
    {
        auto path = uri2local(request.uri);

        writeln("INDEX ", path);
        
        if (path.exists && path.isDir)
            return sendFile(std.path.join(path, "index.html"));
        
        return false;
    }


    bool getDirListing(in RequestLine request, in Header[] headers)
    {
        auto path = uri2local(request.uri), host = getHeaderValue(headers, "Host");

        writeln("LIST ", path);
        
        if (path.exists && path.isDir)
        {
            string page = "<html><body><pre>";

            writeln("..OK");
            
            foreach (filename; path.listDir)
            {
                auto file_path = std.path.join(path, filename);
                
                page ~= format(`%s <a href="%s">%s</a><br/>`,
                    ((file_path.exists && file_path.isDir) ? "DIR " : "    "),
                    "http://" ~ host ~ "/" ~ request.uri ~ "/" ~ filename ~
                        ((file_path.exists && file_path.isDir) ? "/" : ""),
                    filename);
            }

            page ~= "</pre></body></html>";
            sendResponse(STATUS_OK, page);
            
            return true;
        }
        
        return false;
    }
    
    
    string getHeaderValue(in Header[] headers, string name)
    {
        foreach (header; headers)
        {
            if (header.name == name)
                return header.value;
        }
        
        return "";
    }
    

    bool sendFile(string path)
    {
        writeln("SEND ", path);
        
        if (path.exists && path.isFile)
        {
            sendResponse(STATUS_OK, std.file.read(path), getMIMEType(path));
            return true;
        }

        return false;
    }

    string uri2local(string uri)
    {
        return std.path.join(root, uri.skip("/"));
    }

    string getMIMEType(string filename)
    {
        const string[string] types =
        [
            "html": "text/html",
            "txt":  "text/plain",
            "gif":  "image/gif",
            "jpg":  "image/jpeg"
        ];

        return types.get(getExt(filename), "application/octet-stream");
    }

public:
    this(string root, Socket client)
    {
        this.client = client;
        this.root = root;
        super(&run);
    }
}
