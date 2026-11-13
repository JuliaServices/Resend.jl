# Compiled with `juliac --trim=safe` in CI to check that sending and error parsing
# stay trim-safe. The send goes to a closed local port, so it fails to connect and
# nothing reaches Resend.
using Resend

function send()::Bool
    request = Resend.SendEmailRequest(; from = "Team <team@example.com>",
        to = ["a@example.com", "b@example.com"], subject = "Hello", text = "Hi there.",
        html = "<p>Hi there.</p>", reply_to = "coach@example.com",
        scheduled_at = "in 1 hour", headers = Dict("X-Entity-Ref-ID" => "42"))
    try
        Resend.send_email(request; idempotency_key = "trim-1")
        println(Core.stdout, "send_email: unexpected answer")
        return false
    catch e
        e isa Resend.APIError && rethrow()
        println(Core.stdout, "send_email to a closed port failed: ", nameof(typeof(e)))
        return true
    end
end

function (@main)(args::Vector{String})::Cint
    failed = Resend.with_resend(send, "re_trim"; base_url = "http://127.0.0.1:1")
    err = Resend._api_error(422,
        "{\"statusCode\":422,\"name\":\"validation_error\",\"message\":\"Invalid `to` field.\"}")
    parsed = err.status == 422 && err.name == "validation_error" && err.message == "Invalid `to` field."
    println(Core.stdout, "APIError parsed: ", parsed)
    return failed && parsed ? 0 : 1
end
