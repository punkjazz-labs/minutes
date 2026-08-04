import Foundation
import MinutesCore

/// The endpoint is stubbed, so nothing here opens a network connection.
func notesChecks(_ run: CheckRun) async {
    run.section("Notes endpoint")

    func client(baseURL: String = "http://127.0.0.1:4000/v1") -> OpenAICompatibleNotesClient {
        OpenAICompatibleNotesClient(
            baseURL: baseURL,
            model: "profile/general",
            apiKey: "local-placeholder",
            session: StubEndpoint.session())
    }

    let completion = """
        {"choices":[{"message":{"role":"assistant","content":"## Pricing\\n\\nThey asked about renewal [00:01:12]."}}]}
        """

    // A clean enhance.
    StubEndpoint.expect(json: completion)
    do {
        let result = try await client().enhance(
            NotesRequest(title: "Pricing call", ownerNotes: "- pricing concerns", transcript: "[00:01:12] Others: renewal"))
        run.expect(result.markdown.contains("They asked about renewal"), "a clean run returns the notes")
        run.equal(result.model, "profile/general", "the result names the model that wrote it")

        let (request, body) = StubEndpoint.lastRequest()
        run.equal(
            request?.url?.absoluteString ?? "", "http://127.0.0.1:4000/v1/chat/completions",
            "the request goes to the chat completions path")
        run.equal(
            request?.value(forHTTPHeaderField: "x-litellm-customer-id") ?? "", "minutes",
            "the request carries the routing identity")
        run.equal(
            request?.value(forHTTPHeaderField: "Authorization") ?? "", "Bearer local-placeholder",
            "the request carries the configured key")

        let sent = String(decoding: body ?? Data(), as: UTF8.self)
        run.expect(sent.contains("meeting-notes-enhance"), "the request names the operation for the gateway")
        run.expect(sent.contains("Input 1"), "the owner notes are a labelled input")
        run.expect(sent.contains("Input 2"), "the transcript is a labelled input")
        run.expect(sent.contains("pricing concerns"), "what the owner typed is sent as the prompt")
        run.expect(sent.contains("Do not invent decisions"), "the prompt forbids inventing agreements")
        run.expect(!sent.contains("RIFF") && !sent.contains(".wav"), "audio is never sent")
    } catch {
        run.failed("a clean enhance should not throw: \(error.localizedDescription)")
    }

    // A refused connection.
    StubEndpoint.expectFailure(URLError(.cannotConnectToHost))
    do {
        _ = try await client().enhance(NotesRequest(title: "T", ownerNotes: "", transcript: "x"))
        run.failed("a refused connection must be reported")
    } catch let error as NotesError {
        run.expect(error.isRetryable, "a refused connection is retryable")
        run.expect(
            error.localizedDescription.contains("the notes are waiting"),
            "a refused connection says the transcript is saved and the notes wait")
    } catch {
        run.failed("wrong error type for a refused connection")
    }

    // A rejected key.
    StubEndpoint.expect(status: 401, json: "{\"error\":\"no key\"}")
    do {
        _ = try await client().enhance(NotesRequest(title: "T", ownerNotes: "", transcript: "x"))
        run.failed("a rejected key must be reported")
    } catch let error as NotesError {
        run.expect(!error.isRetryable, "a rejected key is not retried silently")
        run.expect(error.localizedDescription.contains("API key"), "the message names the key")
        run.expect(error.localizedDescription.contains("minutes settings"), "the message says where to set it")
    } catch {
        run.failed("wrong error type for a rejected key")
    }

    // An empty answer is not passed off as notes.
    StubEndpoint.expect(json: "{\"choices\":[{\"message\":{\"content\":\"   \"}}]}")
    do {
        _ = try await client().enhance(NotesRequest(title: "T", ownerNotes: "", transcript: "x"))
        run.failed("empty content must not be written as notes")
    } catch let error as NotesError {
        if case .emptyResponse = error {
            run.expect(true, "an empty answer is refused")
        } else {
            run.failed("an empty answer should be reported as empty")
        }
    } catch {
        run.failed("wrong error type for an empty answer")
    }

    // The probe.
    StubEndpoint.expect(json: "{\"data\":[{\"id\":\"profile/general\"},{\"id\":\"profile/fast\"}]}")
    do {
        let models = try await client().probeModels()
        run.equal(models, ["profile/general", "profile/fast"], "the probe lists what the endpoint offers")
        let (request, _) = StubEndpoint.lastRequest()
        run.equal(request?.url?.absoluteString ?? "", "http://127.0.0.1:4000/v1/models", "the probe asks for the model list")
        run.equal(request?.httpMethod ?? "", "GET", "the probe is a GET")
    } catch {
        run.failed("the probe should not throw: \(error.localizedDescription)")
    }

    // A trailing slash in the setting still produces a valid URL.
    StubEndpoint.expect(json: "{\"data\":[]}")
    do {
        _ = try await client(baseURL: "http://127.0.0.1:4000/v1/").probeModels()
        let (request, _) = StubEndpoint.lastRequest()
        run.equal(
            request?.url?.absoluteString ?? "", "http://127.0.0.1:4000/v1/models",
            "a trailing slash in the endpoint setting is handled")
    } catch {
        run.failed("a trailing slash should not break the probe")
    }

    let keyStore = EnvironmentAPIKeyStore(variable: "MINUTES_KEY_THAT_IS_NOT_SET")
    run.expect(keyStore.readKey() == nil, "an unset key reads as nothing")
    run.equal(keyStore.effectiveKey(), "local-placeholder", "an unset key falls back to the documented placeholder")
}
