# hyperserve

A http server framework for Jai that’s very much *NOT DONE YET*.
It’s mostly a place to fool around with HTTP stuff until I have enough pieces together to turn it into a proper framework.

It aspires to become someting similar to [hapi](https://hapi.dev) but without all the Node.js nonsense.

## Request lifecycle

1. When clients connect, the main server thread adds their socket to the main Wait_Group and waits for the whole header to arrive.
2. Once we know we have the full header, the request gets dispatched to one of the request threads for parsing and processing.
3. After parsing the request thread looks up the route for that request.
4. If the route requires authentication, the server tries the next entry in server.default_auth_methods from the request thread.
    1. If the auth function yields on Async_Tasks, the request thread finishes work and the Async_Tasks get queued on the main Wait_Group.
    2. Once all async tasks finish, the request gets re-scheduled on the request threads.
5. If no auth method called `proceed_request_past_authentication` and the server has exhausted all methods, it responds with .UNAUTHORIZED.
6. After authentication, the main route’s request handler is called.
    1. If the request handler yields on Async_Tasks, the request thread finishes work and the Async_Tasks get queued on the main Wait_Group.
    2. Once all async tasks finish, the request gets re-scheduled on the request threads.
7. Step 5 is repeated until the request handler responds or returns without yielding (which casues an automatic 500 response).
8. After the response has been sent, the client gets re-queued on the main Wait_Group for subsequent requests (… if the connection is not supposed to be closed after the request).

