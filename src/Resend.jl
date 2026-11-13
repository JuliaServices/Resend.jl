"""
    Resend

Sends email through Resend's API (`POST /emails`). Requests and answers are typed
structs, a refused request throws [`APIError`](@ref) with Resend's status and
message, and an idempotency key makes a repeated send safe.

Requests use the client that [`with_resend`](@ref) sets for a block of code.

The package compiles with `juliac --trim=safe`.
"""
module Resend

using HTTP, JSON, ScopedValues

"Resend's API host."
const API_BASE_URL = "https://api.resend.com"

# Resend keeps an idempotency key for 24 hours and accepts up to 256 characters.
const MAX_IDEMPOTENCY_KEY_LENGTH = 256

# A send usually runs inside someone's web request or a delivery sweep, so it
# gives up after 10 s without a connection or 30 s without a byte of the answer.
const CONNECT_TIMEOUT_SECONDS = 10
const READ_IDLE_TIMEOUT_SECONDS = 30

"""
    SendEmailRequest(; from, to, subject, text = nothing, html = nothing, ...)

One email for [`send_email`](@ref). Fields are Resend's own: `from` may carry a
display name (`"Team <team@example.com>"`), and `to`, `cc`, `bcc`, and `reply_to`
take one address or a vector of them (`to` at most 50). Give `text`, `html`, or
both. `scheduled_at` delays delivery: an ISO 8601 time or a phrase such as
`"in 1 hour"`. `headers` adds headers to the email itself. Fields left `nothing`
are not sent.
"""
@kwarg struct SendEmailRequest
    from::String
    to::Union{String,Vector{String}}
    subject::String
    bcc::Union{String,Vector{String},Nothing} = nothing
    cc::Union{String,Vector{String},Nothing} = nothing
    scheduled_at::Union{String,Nothing} = nothing
    reply_to::Union{String,Vector{String},Nothing} = nothing
    html::Union{String,Nothing} = nothing
    text::Union{String,Nothing} = nothing
    headers::Union{Dict{String,String},Nothing} = nothing
end

"""
    SendEmailResponse

Resend's answer to an accepted send. `id` names the email in Resend's dashboard,
webhooks, and API.
"""
@kwarg struct SendEmailResponse
    id::String
end

"""
    APIError(status, name, message)

Resend refused a request with HTTP `status`. `name` is Resend's error type, such
as `"validation_error"`, `"rate_limit_exceeded"`, or
`"concurrent_idempotent_requests"`; it is empty when the answer did not carry one.
`message` is Resend's explanation, or the answer's text when it is not Resend's
JSON error shape.

A 429 or 5xx can succeed when sent again; send it with the same idempotency key.
"""
struct APIError <: Exception
    status::Int
    name::String
    message::String
end

Base.showerror(io::IO, e::APIError) = print(io, "Resend.APIError (HTTP ", e.status,
    isempty(e.name) ? "" : string(", ", e.name), "): ", e.message)

@defaults struct _ErrorBody
    name::Union{String,Nothing} = nothing
    message::Union{String,Nothing} = nothing
end

function _api_error(status::Int, body::String)::APIError
    parsed = try
        JSON.parse(body, _ErrorBody)
    catch
        nothing
    end
    name = parsed === nothing ? nothing : parsed.name
    message = parsed === nothing ? nothing : parsed.message
    text = strip(body)
    fallback = isempty(text) ? "Resend answered HTTP $status" : first(text, 500)
    return APIError(status, something(name, ""),
        message === nothing || isempty(message) ? fallback : message)
end

struct Client
    api_key::String
    base_url::String
end

const RESEND_CLIENT = ScopedValue{Union{Client,Nothing}}(nothing)

"""
    with_resend(f, api_key; base_url = Resend.API_BASE_URL)

Run `f()` with a client for `api_key`; every [`send_email`](@ref) inside `f`
uses it. `base_url` points the client at another server, such as a local stub in
tests.

```julia
Resend.with_resend(ENV["RESEND_API_KEY"]) do
    Resend.send_email(Resend.SendEmailRequest(; from = "Team <team@example.com>",
        to = "player@example.com", subject = "Welcome", text = "Glad you're here."))
end
```
"""
function with_resend(f::F, api_key::String; base_url::String = API_BASE_URL) where {F}
    @with RESEND_CLIENT => Client(api_key, base_url) f()
end

function _get_client()::Client
    client = RESEND_CLIENT[]
    client === nothing && error("No Resend client set. Use `with_resend` to set credentials.")
    return client
end

"""
    send_email(req::SendEmailRequest; idempotency_key = nothing) -> SendEmailResponse

Send one email. Throws [`APIError`](@ref) when Resend refuses it, and HTTP.jl's
connection or timeout errors when Resend can't be reached.

The call never sends the request twice. A send whose answer was lost may still
have gone out, so retry with the same `idempotency_key` (1 to 256 characters):
for 24 hours Resend answers a repeated key with the first send's answer instead
of sending again, and refuses the key with a different email (HTTP 409).
"""
function send_email(req::SendEmailRequest;
                    idempotency_key::Union{String,Nothing} = nothing)::SendEmailResponse
    client = _get_client()
    headers = ["Authorization" => "Bearer $(client.api_key)",
               "Content-Type" => "application/json", "Accept" => "application/json"]
    if idempotency_key !== nothing
        1 <= length(idempotency_key) <= MAX_IDEMPOTENCY_KEY_LENGTH || throw(ArgumentError(
            "Resend idempotency keys are 1 to $MAX_IDEMPOTENCY_KEY_LENGTH characters"))
        push!(headers, "Idempotency-Key" => idempotency_key)
    end
    # HTTP.jl resends a request that carries an Idempotency-Key unless retry = false.
    # Without redirect = false it would send the API key on to a redirect's host.
    response = HTTP.request("POST", rstrip(client.base_url, '/') * "/emails", headers,
        JSON.json(req; omit_null = true);
        retry = false, redirect = false, status_exception = false,
        connect_timeout = CONNECT_TIMEOUT_SECONDS, read_idle_timeout = READ_IDLE_TIMEOUT_SECONDS)
    body = String(response.body)
    200 <= response.status < 300 || throw(_api_error(Int(response.status), body))
    return JSON.parse(body, SendEmailResponse)
end

end # module Resend
