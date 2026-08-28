# 0003: notes go to a configurable OpenAI-compatible endpoint, defaulting to the LiteLLM profile aliases

Date: 2026-08-04
Status: accepted for v0.1

## Context

Spec 17 sends the transcript to a Spark through basement's stable `/v1`
endpoint, addressing `role/reasoning`, with an API key generated on the
Connect tab.

The owner's universal project defaults say something different and more
general: applications should not depend on concrete backend model names, and
should address the LiteLLM gateway using stable profile aliases, sending a
customer id header and an operation name in request metadata.

These are not in conflict about protocol. Both are OpenAI-compatible `/v1`
endpoints and both take a bearer key. They differ about which host and which
model name is the default.

## Decision

The endpoint and the model are settings, not constants. Their defaults are:

- base URL `http://127.0.0.1:4000/v1`, the LiteLLM gateway on the machine the
  app runs on
- model `profile/general`, a profile alias rather than a checkpoint name

No other machine address appears anywhere in the source. Pointing minutes at a
Spark, at the gateway on another host, or at any other OpenAI-compatible
server is a settings change and needs no code change.

Every request carries:

- `Authorization: Bearer <key>`
- `x-litellm-customer-id: minutes`, the stable application id
- `metadata: {"operation": "meeting-notes-enhance"}` in the JSON body

The operation to profile mapping still has to be registered in the profile
registry on the gateway host before this app sends production traffic. That
registration is not done by this repository and is not claimed to be done.

## The key

The API key lives in the login keychain as a generic password under service
`com.punkjazz.minutes`, account `notes-endpoint-api-key`. It is never written
to user defaults, to a file in the repository, or to a log line.

When no key is set, the client sends the string `local-placeholder`. That is
not a secret and is documented as a placeholder: OpenAI-compatible clients
require a non-empty field, and a local gateway accepts anything there. The
settings panel says this in as many words rather than showing an empty field
that looks broken.

`minutes-cli` reads the key from `MINUTES_API_KEY` instead of the keychain,
because keychain access from a bare command line binary prompts in a way that
is not useful in a script.

## Streaming

The spec asks for streamed output. v0.1 sends one request and waits for the
whole answer. Streaming is a v0.2 change to `NotesGenerating`, which is a
protocol precisely so this does not reach into the rest of the app.

## What happens when the endpoint is not there

The transcript is written before the endpoint is called. A refused connection
produces a `notes.md` with `notes_state: pending`, the reason in plain
language, and everything the owner typed kept byte for byte. A meeting is
never lost because a machine was off.
