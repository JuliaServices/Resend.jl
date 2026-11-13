# Resend.jl

[![CI](https://github.com/JuliaServices/Resend.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaServices/Resend.jl/actions/workflows/ci.yml)

Send email from Julia through [Resend](https://resend.com)'s API. Requests and
answers are typed structs, and the package compiles with `juliac --trim=safe`.

It covers sending one email (`POST /emails`) and grows as callers need more.

## Use

Set the API key for a block of code; every send inside uses it.

```julia
using Resend

Resend.with_resend(ENV["RESEND_API_KEY"]) do
    response = Resend.send_email(Resend.SendEmailRequest(;
            from = "Team <team@example.com>",
            to = "player@example.com",
            subject = "Welcome",
            text = "Glad you're here.",
            html = "<p>Glad you're here.</p>");
        idempotency_key = "welcome-player-42")   # safe to send again
    response.id                                  # Resend's id for the email
end
```

`SendEmailRequest` takes Resend's fields: `from`, `to`, `subject`, `text`,
`html`, `cc`, `bcc`, `reply_to`, `scheduled_at`, and `headers`. Fields left
`nothing` are not sent.

Pass `base_url` to `with_resend` to point the client at another server, such as
a local stub in tests.

## Errors and retries

- `Resend.APIError`: Resend refused the request. It carries the HTTP `status`,
  Resend's error `name` (such as `"validation_error"`), and its `message`.
- HTTP.jl's connection and timeout errors: Resend could not be reached (10 s to
  connect, 30 s without a byte of the answer).

`send_email` never sends a request twice. A send whose answer was lost may still
have gone out, so retry with the same `idempotency_key`: for 24 hours Resend
answers a repeated key with the first send's answer instead of sending again.
