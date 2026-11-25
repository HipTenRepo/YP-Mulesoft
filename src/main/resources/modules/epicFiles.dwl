%dw 2.0
// Helpers for epic-files.xml (Applied Epic files: list, link, download).
import encodeURIComponent from dw::core::URL
import some from dw::core::Arrays

// Salesforce record type -> Applied Epic attachments filter. Null = not supported.
fun filterParam(epicType) =
    { Client: "account", Opportunity: "opportunity", Policy: "policy" }[epicType default ""]

// Applied Epic path of one record, used to tell an unknown record (404) from one with no files.
fun recordPath(epicType, epicId) =
    ({ Client: "/epic/client/v1/clients/", Opportunity: "/epic/opportunity/v1/opportunities/", Policy: "/epic/policy/v2/policies/" }[epicType default ""] default "") ++ (epicId default "")

// Applied Epic sends file.name as the original path (C:\Users\...\x.docx, \\server\...\x.pdf, a/b.docx).
// Keep only the last part, so no local paths reach the browser or the log.
fun fileName(path) = ((path default "") splitBy /[\\\/]/ filter (not isBlank($)))[-1] default ""

// Name for the saved file: Applied's name plus its extension when the name lacks it ("Agenda" + eml -> "Agenda.eml").
fun downloadName(name, ext) =
    if (isBlank(ext) or (lower(name default "") endsWith ("." ++ lower(ext)))) name
    else name ++ "." ++ ext

fun isPreviewType(ext, previewTypes) =
    ((previewTypes splitBy ",") map trim(lower($))) contains lower(ext default "")

// Over the preview size limit. previewMaxBytes 0 = no limit.
fun isTooLarge(size, previewMaxBytes) = (previewMaxBytes > 0) and (size > previewMaxBytes)

// Applied Epic attachment -> file row for the files component.
fun toFile(att, previewMaxBytes, previewTypes) = do {
    var file = att.file default {}
    var size = (file.size default 0) as Number
    var ext = lower((file.extension default "") replace /^\./ with "")
    var available = file.status == "OK"
    ---
    {
        id: att.id,
        name: if (isBlank(fileName(file.name))) (att.description default "") else fileName(file.name),
        "type": ext,
        sizeBytes: size,
        description: att.description default "",
        attachedDate: att.attachedOn default "",
        folderId: att.folder default "",
        available: available,
        tooLarge: isTooLarge(size, previewMaxBytes),
        // What /files/link would accept with mode=preview: available, a preview type (PDF or image), not too large.
        canPreview: available and isPreviewType(ext, previewTypes) and (not isTooLarge(size, previewMaxBytes))
    }
}

// The file must be on the Applied Epic record the producer is on.
// Client: the attachment's account. Opportunity / Policy: one of its attachedTos.
fun belongsTo(att, epicType, epicId) =
    if (epicType == "Client") (att.account default "") == epicId
    else ((att.attachedTos default []) some ((t) -> upper(t."type" default "") == upper(epicType) and t.id == epicId))

// Expected Applied Epic failures -> result code for the component. Anything else: UNAVAILABLE.
fun failureCode(err) =
    if ((err.errorType.namespace == "HTTP") and (["NOT_FOUND", "BAD_REQUEST"] contains (err.errorType.identifier default ""))) "NOT_FOUND"
    else "UNAVAILABLE"

// Content types we send. Anything else goes out as application/octet-stream (download only).
var contentTypes = {
    pdf: "application/pdf",
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    gif: "image/gif",
    tif: "image/tiff",
    tiff: "image/tiff",
    txt: "text/plain",
    csv: "text/csv",
    doc: "application/msword",
    docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    xls: "application/vnd.ms-excel",
    xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ppt: "application/vnd.ms-powerpoint",
    pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    msg: "application/vnd.ms-outlook",
    eml: "message/rfc822",
    zip: "application/zip"
}

fun contentType(ext) = contentTypes[lower(ext default "")] default "application/octet-stream"

// Quotes, backslashes and line breaks out; non-ASCII becomes _ in the plain filename (the full name goes in filename*).
fun contentDisposition(kind, name) = do {
    var clean = (name default "file") replace /["\\\r\n]/ with ""
    var ascii = clean replace /[^\x20-\x7E]/ with "_"
    ---
    kind ++ "; filename=\"" ++ ascii ++ "\"; filename*=UTF-8''" ++ encodeURIComponent(clean)
}

// Response headers for GET /download/{token}.
// Preview: inline, framed only by the environment's Lightning domains; images also sandboxed.
// Download: attachment, never framed.
fun responseHeaders(link, frameAncestors) = do {
    var preview = link.mode == "preview"
    var isImage = contentType(link.extension) startsWith "image/"
    ---
    {
        "Content-Type": if (preview or contentTypes[lower(link.extension default "")] != null) contentType(link.extension) else "application/octet-stream",
        "Content-Disposition": contentDisposition(if (preview) "inline" else "attachment", link.name),
        "Content-Security-Policy":
            if (preview) ("frame-ancestors " ++ frameAncestors ++ (if (isImage) "; sandbox" else ""))
            else "frame-ancestors 'none'",
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer"
    }
}
