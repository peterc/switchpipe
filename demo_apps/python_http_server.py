import SimpleHTTPServer
import sys
import SocketServer

# Ultra simple Python HTTP daemon. Make sure to provide
# a port number as the first and only argument.

Handler = SimpleHTTPServer.SimpleHTTPRequestHandler
httpd = SocketServer.TCPServer(("", int(sys.argv[1])), Handler)
httpd.serve_forever()
