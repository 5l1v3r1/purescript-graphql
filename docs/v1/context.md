# The execution context

Let's take a deeper look into what happens when a client sends a query to the API server. We have just build an HTTP server that will answer POST requests and parse the request body to extract the query, operation name and variabes. The three are the parameters the client specifies and supplies to the GraphQL execution.
