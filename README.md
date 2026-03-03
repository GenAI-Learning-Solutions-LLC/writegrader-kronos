# writegrader-kronos

Backend API server for [WriteGrader](https://writegrader.com), built on [Zoi](./ZOI.md) — a minimal Zig HTTP server. Handles assignments, submissions, grading, and user auth against AWS DynamoDB.

## Platform

Development runs on macOS and Linux. Production runs on FreeBSD. The codebase is expected to remain compatible with all three. Zig's cross-compilation support and the avoidance of platform-specific dependencies keep this straightforward, but any new C code or system calls should be verified against FreeBSD.

## Stack

- **Zig 0.16** — application server
- **DynamoDB** — primary data store, accessed via a custom C client (`src/dynamo.c`)
- **libcurl** — used by `dynamo.c` to make signed DynamoDB HTTP requests
- **SQLite / libsqlite3** — request-scoped cache to reduce DynamoDB round trips
- **JWT** — cookie-based auth (`userToken`)
- **Caddy** — production TLS termination and reverse proxy; the Zig server binds locally and Caddy handles HTTPS

## Project Structure

```
src/
  main.zig              — entry point
  routes.zig            — route table
  server.zig            — core server, router, sendJson, makeHeaders
  dynamo.zig            — DynamoDB helpers (getItemPkSk, getUser, saveItem, …)
  dynamo.c / dynamo.h   — custom C DynamoDB client (libcurl)
  sql.zig               — SQLite cache (exec, getAll)
  auth.zig              — JWT decode
  config.zig            — loads config.json
  fmt.zig               — template rendering
  utils.zig             — shared utilities
  schema.zig            — re-exports schema types
  schema/
    assignment.zig      — Assignment struct and related types
  routes/
    assignment_routes.zig
    submission_routes.zig
    grade_routes.zig
    user_routes.zig
config.json             — bind address, port, worker count
```

## Running

```sh
./dev.sh
```

The server starts on the address and port in `config.json` (default `127.0.0.1:8081`).

## Configuration

```json
{
    "address": "127.0.0.1",
    "port": "8081",
    "workers": 3
}
```

## API Routes

All routes require a valid `userToken` cookie (JWT, verified by `authMiddleware`).

### Assignments

| Method | Path | Handler |
|--------|------|---------|
| `GET` | `/assignments/:cid/:aid` | `getAssignment` |
| `GET` | `/courses/:cid/assignments/:aid` | `getAssignment` |
| `GET` | `/classes/:cid/assignments/:aid` | `getAssignment` |
| `GET` | `/courses/:cid/assignments/:aid/submissions` | `getAssignmentSubmissions` |
| `PUT` | `/submissions` | `saveSubmission` |
| `GET` | `/submissions` | `getAllSubmissions` |
| `GET` | `/courses/:cid/assignments/:aid/submissions/:sid` | `get_submission` |
| `POST` | `/grade` | `grade` |
| `POST` | `/grade/criterion` | `gradeCriterion` |

## Writing a Route

Define a handler in a routes file, register it in `src/routes.zig`, and use `authMiddleware` if the route requires authentication.

**1. Handler** (`src/routes/assignment_routes.zig`):

```zig
const ItemParams = struct { id: []const u8 };

pub fn getItem(c: *Context) !void {
    const headers = try server.makeHeaders(c.allocator, c.request);
    const params = try server.Parser.params(ItemParams, c);
    const user = dynamo.getUser(c) catch {
        try c.request.respond("", .{ .status = .forbidden, .extra_headers = headers });
        return;
    };

    const item = (try dynamo.getItemPkSk(MySchema, c.allocator, "ITEM", user.email, params.id)) orelse {
        try c.request.respond("", .{ .status = .not_found, .extra_headers = headers });
        return;
    };

    try server.sendJson(c.allocator, c.request, item, .{ .extra_headers = headers });
}
```

**2. Registration** (`src/routes.zig`):

```zig
.{ .path = "/items/:id", .middleware = &[_]Callback{ authMiddleware }, .callback = my_routes.getItem },
```

For endpoints that don't need to modify the data, return the raw DynamoDB bytes directly instead of parsing into a struct and re-serializing — this avoids dropping fields not present in the Zig type:

```zig
// Fetch raw bytes, parse only what's needed for auth/logic
const raw = dynamo.c.get_item_pk_sk(cpx, cpk, csk) orelse {
    try c.request.respond("", .{ .status = .not_found, .extra_headers = headers });
    return;
};
defer std.c.free(raw);
const slice = std.mem.span(raw);
const owner = try std.json.parseFromSliceLeaky(struct { OWNER: []const u8 }, c.allocator, slice, .{
    .ignore_unknown_fields = true, .allocate = .alloc_always,
});
if (!std.mem.eql(u8, owner.OWNER, user.email)) {
    try c.request.respond("", .{ .status = .forbidden, .extra_headers = headers });
    return;
}
try c.request.respond(slice, .{ .extra_headers = headers });
```

## Auth

`authMiddleware` runs before every protected route. It:
1. Reads the `userToken` cookie
2. Decodes and verifies the JWT
3. Looks up the user record in SQLite cache (5 min TTL), falling back to DynamoDB
4. Stores the user JSON in the request context for handlers to read via `dynamo.getUser`

## Caching

SQLite is used as a request cache with per-user TTLs:

- **User records** — 5 minutes (`fetch_cache` table, `data_type = 'user'`)
- **Assignment lists** — 10 minutes (`data_type = 'assignments'`)

Cache is invalidated explicitly on write (e.g. `invalidateAssignmentCache`).

## DynamoDB Patterns

Keys follow the pattern `DATATYPE#value`. The C library prefixes both pk and sk automatically:

```zig
// Looks up pk="ASSIGNMENT#<pk>", sk="ASSIGNMENT#<sk>"
dynamo.getItemPkSk(Assignment, allocator, "ASSIGNMENT", pk, sk)
```

Shared/library assignments use `pk = "ASSIGNMENT#Shared:<group>"`.

## Frontend Schema Compatibility

The `Assignment` struct in `src/schema/assignment.zig` is kept in sync with `AssignmentSchema` in [atlas-core](../atlas/packages/core/src/models/schemas/assignment.ts). Two rules that must be maintained:

- `sendJson` uses `emit_null_optional_fields = false` — the frontend's `v.optional(...)` expects absent fields, not `null`
- `AssignmentSetting.value` defaults to `= .{ .string = "" }` — the schema expects `string | boolean`, not `null`

For read-only GET endpoints, prefer returning raw DynamoDB JSON directly rather than parsing and re-serializing through the struct, to avoid dropping unknown fields.
