using Test, Resend, HTTP, JSON, Sockets

const KEY = "re_test_key"

function free_port()
    port, listener = Sockets.listenany(Sockets.localhost, 0)
    close(listener)
    return Int(port)
end

# Runs `f(seen)` inside `with_resend`, pointed at a local server that answers every
# request with `answer(req)` (a status and a body) and records each request in `seen`.
function with_stub(f, answer; server_kwargs...)
    port = free_port()
    seen = NamedTuple[]
    server = HTTP.serve!("127.0.0.1", port; server_kwargs...) do req
        headers = Dict(name => HTTP.header(req, name, "") for name in
            ("Authorization", "Content-Type", "Idempotency-Key"))
        push!(seen, (; method = req.method, target = req.target, body = String(req.body), headers))
        status, body = answer(req)
        return HTTP.Response(status, ["Content-Type" => "application/json"], body)
    end
    try
        return Resend.with_resend(() -> f(seen), KEY; base_url = "http://127.0.0.1:$port")
    finally
        close(server)
    end
end

accepted(req) = (200, """{"id":"email_1","extra":"ignored"}""")

hello(; kwargs...) = Resend.SendEmailRequest(; from = "Team <team@example.com>",
    to = "player@example.com", subject = "Hello", text = "Hi there.", kwargs...)

caught(f) = try f(); nothing catch e; e end

@testset "Resend" begin
    @testset "send_email posts the request as JSON and parses the answer" begin
        with_stub(accepted) do seen
            response = Resend.send_email(hello(; html = "<p>Hi there.</p>",
                cc = ["a@example.com", "b@example.com"], reply_to = "coach@example.com",
                scheduled_at = "2026-11-14T09:00:00Z", headers = Dict("X-Entity-Ref-ID" => "42")))
            @test response isa Resend.SendEmailResponse
            @test response.id == "email_1"
            request = only(seen)
            @test request.method == "POST"
            @test request.target == "/emails"
            @test request.headers["Authorization"] == "Bearer $KEY"
            @test request.headers["Content-Type"] == "application/json"
            @test request.headers["Idempotency-Key"] == ""
            @test JSON.parse(request.body) == Dict(
                "from" => "Team <team@example.com>", "to" => "player@example.com",
                "subject" => "Hello", "text" => "Hi there.", "html" => "<p>Hi there.</p>",
                "cc" => ["a@example.com", "b@example.com"], "reply_to" => "coach@example.com",
                "scheduled_at" => "2026-11-14T09:00:00Z",
                "headers" => Dict("X-Entity-Ref-ID" => "42"))
        end
    end

    @testset "a base URL with a path or trailing slash keeps it" begin
        port = free_port()
        targets = String[]
        server = HTTP.serve!("127.0.0.1", port) do req
            push!(targets, req.target)
            HTTP.Response(200, """{"id":"email_2"}""")
        end
        try
            Resend.with_resend(KEY; base_url = "http://127.0.0.1:$port/resend/") do
                @test Resend.send_email(hello()).id == "email_2"
            end
        finally
            close(server)
        end
        @test targets == ["/resend/emails"]
    end

    @testset "the idempotency key goes in the Idempotency-Key header" begin
        with_stub(accepted) do seen
            Resend.send_email(hello(); idempotency_key = "welcome-player-42")
            @test only(seen).headers["Idempotency-Key"] == "welcome-player-42"
        end
        with_stub(accepted) do seen
            @test_throws ArgumentError Resend.send_email(hello(); idempotency_key = "")
            @test_throws ArgumentError Resend.send_email(hello(); idempotency_key = "k"^257)
            Resend.send_email(hello(); idempotency_key = "k"^256)
            @test length(seen) == 1
        end
    end

    @testset "a refused request throws APIError with Resend's status and message" begin
        refusal = """{"statusCode":422,"name":"validation_error","message":"Invalid `to` field."}"""
        with_stub(req -> (422, refusal)) do seen
            err = caught(() -> Resend.send_email(hello()))
            @test err isa Resend.APIError
            @test err.status == 422
            @test err.name == "validation_error"
            @test err.message == "Invalid `to` field."
            @test sprint(showerror, err) ==
                "Resend.APIError (HTTP 422, validation_error): Invalid `to` field."
        end
        with_stub(req -> (500, "upstream exploded")) do seen
            err = caught(() -> Resend.send_email(hello()))
            @test err isa Resend.APIError
            @test (err.status, err.name, err.message) == (500, "", "upstream exploded")
            @test sprint(showerror, err) == "Resend.APIError (HTTP 500): upstream exploded"
        end
        with_stub(req -> (502, "")) do seen
            @test caught(() -> Resend.send_email(hello())).message == "Resend answered HTTP 502"
        end
    end

    @testset "a send is never repeated, even with an idempotency key" begin
        # HTTP.jl would resend a keyed request after a 503; the caller decides instead.
        with_stub(req -> (503, """{"name":"internal_server_error","message":"Try again."}""")) do seen
            err = caught(() -> Resend.send_email(hello(); idempotency_key = "k1"))
            @test err isa Resend.APIError && err.status == 503
            @test length(seen) == 1
        end
        # A server that closes the connection without answering.
        port, listener = Sockets.listenany(Sockets.localhost, 0)
        connections = Ref(0)
        acceptor = @async try
            while true
                sock = Sockets.accept(listener)
                connections[] += 1
                readavailable(sock)
                close(sock)
            end
        catch
        end
        err = try
            Resend.with_resend(KEY; base_url = "http://127.0.0.1:$port") do
                Resend.send_email(hello(); idempotency_key = "k2")
            end
            nothing
        catch e
            e
        finally
            close(listener)
        end
        @test err !== nothing && !(err isa Resend.APIError)
        @test connections[] == 1
    end

    @testset "a keep-alive connection the server closed while idle does not fail the next send" begin
        # The server drops idle connections after 1 s; the client reuses its pool after 2 s.
        with_stub(accepted; idle_timeout = 1) do seen
            @test Resend.send_email(hello()).id == "email_1"
            sleep(2)
            @test Resend.send_email(hello()).id == "email_1"
            @test length(seen) == 2
        end
    end

    @testset "sends need a client" begin
        @test_throws ErrorException Resend.send_email(hello())
        @test Resend.with_resend(() -> 42, KEY) == 42
    end
end
