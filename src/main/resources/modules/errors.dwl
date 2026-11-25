%dw 2.0
// Global error handling: error type -> HTTP status + code + caller-facing message.
// Add a row when a new error type needs its own status. Anything not listed becomes 500 INTERNAL_ERROR.
var errorTable = {
    "APIKIT:BAD_REQUEST":            { status: 400, code: "BAD_REQUEST",            exposeDescription: true },
    "APIKIT:NOT_FOUND":              { status: 404, code: "NOT_FOUND",              exposeDescription: false },
    "APIKIT:METHOD_NOT_ALLOWED":     { status: 405, code: "METHOD_NOT_ALLOWED",     exposeDescription: false },
    "APIKIT:NOT_ACCEPTABLE":         { status: 406, code: "NOT_ACCEPTABLE",         exposeDescription: false },
    "APIKIT:UNSUPPORTED_MEDIA_TYPE": { status: 415, code: "UNSUPPORTED_MEDIA_TYPE", exposeDescription: false },
    "APIKIT:NOT_IMPLEMENTED":        { status: 501, code: "NOT_IMPLEMENTED",        exposeDescription: false }
}

var fallback = { status: 500, code: "INTERNAL_ERROR", exposeDescription: false }

// HTTP:* errors come from outbound calls (Applied Epic), so the caller gets 502.
var upstream = { status: 502, code: "UPSTREAM_ERROR", exposeDescription: false }

var defaultMessages = {
    "404": "Resource not found.",
    "405": "Method not allowed.",
    "406": "Not acceptable.",
    "415": "Unsupported media type.",
    "500": "Unexpected error. Quote the correlation id when reporting it.",
    "502": "A downstream system (Applied Epic) returned an error. Quote the correlation id when reporting it.",
    "501": "Not implemented."
}

fun errorKey(err) = (err.errorType.namespace default "") ++ ":" ++ (err.errorType.identifier default "")

fun errorEntry(err) = errorTable[errorKey(err)] default (if (err.errorType.namespace == "HTTP") upstream else fallback)

fun errorStatus(err) = errorEntry(err).status

fun errorBody(err, correlationId) = do {
    var entry = errorEntry(err)
    ---
    {
        correlationId: correlationId,
        code: entry.code,
        message: if (entry.exposeDescription) (err.description default "Bad request.")
                 else (defaultMessages[entry.status as String] default "Unexpected error."),
        timestamp: now()
    }
}
