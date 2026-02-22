# Todo / Known Bugs

## Bugs

### Router always calls 404 after a successful match (`server.zig:161-176`)
The for loop has no `return` after `r.run(c)` succeeds. After a route handler responds, execution falls through and `notFound.callback` is always called. The second respond fails on the already-responded connection, `route` returns an error, `errdefer state.* = .err` fires, and the worker is marked as crashed and respawned. Every successful request is silently killing a worker. The server keeps running due to auto-respawn but this is unintentional.

Fix: add `return;` after the successful `r.run` path.

### Dotfile block doesn't return (`server.zig:105-108`)
The `hideDotFiles` check sends a 403 but has no `return` after it. Execution continues and the file gets served anyway. Dotfiles are being sent to clients despite the 403.

Fix: add `return;` after the forbidden response.

### Double-free in `static` (`server.zig:132` and `135`)
`defer allocator.free(body)` appears twice in the same scope. The arena allocator ignores frees so this doesn't crash in practice, but it would double-free with any non-arena allocator.

Fix: remove the second `defer allocator.free(body)` at line 135.

### `triggerClose` references non-existent `self.lock` (`server.zig:191-195`)
`Server` has no `lock` field. `triggerClose` is a compile error if called. The `shouldClose` flag it's meant to set is also accessed without synchronization in the monitor loop.

Fix: either add a mutex field to `Server` or use an atomic for `shouldClose`.

### `auth.zig` won't compile (`auth.zig:8`)
`std.io.getstdout()` should be `std.io.getStdOut()`. Currently not imported anywhere so it doesn't block the build, but the file is broken.

Fix: correct the capitalisation.

## Minor

- Lines 254-260 in `runServer` are unreachable: two lines of debug print after `std.process.exit(0)`, and `try self.listen(0, &state, router)` after `while (true)`.
- `worker_states` memory is uninitialized when the monitor loop first reads it. The 1-second sleep makes this unlikely to matter in practice.
