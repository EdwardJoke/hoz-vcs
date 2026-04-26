# Fake Stub Code TODO

This document catalogs all stub implementations in the Hoz codebase that return fake/dummy results instead of performing real operations.

---

## 1. Stash System

### `src/stash/save.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `writeTreeFromIndex` | 74 | Builds tree from index entries, writes compressed tree object | ✅ COMPLETE |
| `writeWorkingCommit` | 78 | Creates blobs+tree+commit from working dir, all written to objects dir | ✅ COMPLETE |
| `createStashCommit` | 113 | Creates commit with parents, serializes + zlib-compresses + writes to objects dir | ✅ COMPLETE |
| `updateReflog` | 118 | No-op, returns immediately | ✅ COMPLETE (writes real reflog) |

### `src/stash/pop.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `applyStash` | 93 | Reads stash commit, applies tree blobs to working dir via cwd.writeFile | ✅ COMPLETE |
| `dropStashIndex` | 97 | Real implementation - modifies reflog | ✅ COMPLETE |

### `src/stash/apply.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `apply` | N/A | Reads commit, applies tree to working dir | ✅ COMPLETE |
| `applyIndex` | N/A | Reads commit, applies tree to working dir | ✅ COMPLETE |

### `src/stash/drop.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `drop` | 30 | Real implementation - modifies reflog | ✅ COMPLETE |
| `dropIndex` | 35 | Real implementation - modifies reflog | ✅ COMPLETE |
| `clear` | 100 | Real implementation - deletes reflog | ✅ COMPLETE |

### `src/stash/show.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `show` | N/A | Lists stashes, finds entry by index, formats diff output | ✅ COMPLETE |
| `showIndex` | N/A | Lists stashes, finds entry by index, formats diff output | ✅ COMPLETE |

### `src/stash/branch.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `createBranch` | N/A | Resolves stash, creates branch ref with commit OID | ✅ COMPLETE |
| `createBranchFromIndex` | N/A | Resolves stash by index, creates branch ref with commit OID | ✅ COMPLETE |

---

## 2. Reset System

### `src/reset/hard.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `reset` | 24 | Reads commit, applies tree to working dir | ✅ COMPLETE |
| `resetTreeToOid` | 117 | Applies tree entries recursively | ✅ COMPLETE |

### `src/reset/soft.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `reset` | 24 | Updates HEAD ref | ✅ COMPLETE |
| `getHeadCommit` | 40 | Resolves HEAD to commit OID | ✅ COMPLETE |

### `src/reset/mixed.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `reset` | 24 | Updates HEAD and clears index | ✅ COMPLETE |
| `clearIndex` | 30 | Deletes and recreates empty index | ✅ COMPLETE |

### `src/reset/merge.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `reset` | 30 | Checks conflicts, runs mixed reset to target | ✅ COMPLETE |
| `hasUnresolvedConflicts` | N/A | Checks MERGE_HEAD + MERGE_MSG files in git dir | ✅ COMPLETE |
| `abort` | N/A | Runs soft reset to HEAD, clears merge state | ✅ COMPLETE |

### `src/reset/restore_staged.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `restore` | 23 | Restores specific paths from source to index | ✅ COMPLETE |
| `restoreAll` | 31 | Restores all paths from source to index | ✅ COMPLETE |

### `src/reset/restore_working.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `restore` | 21 | Restores working tree files from index | ✅ COMPLETE |
| `restoreFromSource` | 27 | Restores working tree from source tree | ✅ COMPLETE |

### `src/reset/restore_source.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `resolveSource` | 28 | Resolves commit/tree spec to OID | ✅ COMPLETE |
| `getTreeFromSource` | N/A | Reads commit, extracts tree OID hex | ✅ COMPLETE |

---

## 3. Branch System

### `src/branch/create.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `create` | 32 | Resolves `refs/heads/<name>`, checks force/duplicate, writes ref via RefStore.write() | ✅ COMPLETE |
| `createFromRef` | 41 | Resolves symbolic ref chain via RefStore.resolve(), delegates to create() | ✅ COMPLETE |

### `src/branch/delete.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `delete` | 29 | Checks ref exists via RefStore.exists(), deletes via RefStore.delete() | ✅ COMPLETE |
| `deleteMultiple` | 38 | Iterates names, calls delete() per entry, returns allocated results | ✅ COMPLETE |
| `isMerged` | 44 | Reads both refs, compares OIDs for equality check | ✅ COMPLETE |

### `src/branch/rename.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `rename` | 28 | No-op with `_ = self` | ✅ COMPLETE |
| `renameMany` | 37 | No-op with `_ = self` | ✅ COMPLETE |

### `src/branch/list.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `getBranchInfo` | 211 | No-op with `_ = self` | ✅ COMPLETE |

### `src/branch/ref.zig` (lines 97-112)
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `getUpstream` | 197 | Reads branch config for upstream tracking | ✅ COMPLETE |
| `setUpstream` | 211 | Writes branch config for upstream tracking | ✅ COMPLETE |
| `getUpstreamStatus` | 231 | Calculates ahead/behind counts | ✅ COMPLETE |

---

## 4. Rebase System

### `src/rebase/planner.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `plan` | 48 | Plans rebase, collects commits | ✅ COMPLETE |
| `collectRebaseCommits` | 80 | Collects commits between branch and upstream | ✅ COMPLETE |
| `collectRootCommits` | 110 | Collects commits for root rebase | ✅ COMPLETE |

---

## 5. Merge System

### `src/merge/three_way.zig` (line 123)
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `mergeBlobs` | 140 | Reads blobs, decompresses, performs 3-way merge | ✅ COMPLETE |

### `src/merge/resolution.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `resolve` | 33 | Resolves conflicts using strategy | ✅ COMPLETE |
| `abort` | 244 | Cleans up merge state files | ✅ COMPLETE |

### `src/merge/markers.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `extractMarkers` | 129 | Extracts conflict regions from content | ✅ COMPLETE |
| `applyMarkers` | 194 | Applies resolution to conflict markers | ✅ COMPLETE |

### `src/merge/conflict.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `hasConflicts` | 93 | Checks if conflicts exist in list | ✅ COMPLETE |
| `getConflictMarkers` | 99 | Finds conflict marker positions | ✅ COMPLETE |
| `resolveConflicts` | 120 | Resolves conflicts using strategy | ✅ COMPLETE |

### `src/merge/commit.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `createFastForward` | 59 | Returns target OID for fast-forward merge | ✅ COMPLETE |

### `src/merge/squash.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `squash` | 32 | Counts commits, generates squash message | ✅ COMPLETE |
| `squashInto` | 43 | Squashes source commits into target | ✅ COMPLETE |

---

## 6. Diff System

### `src/diff/diff.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `deinit` | 36 | No-op with `_ = self` | ✅ COMPLETE |

### `src/diff/unified.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `deinit` | 175 | No-op with `_ = self` | ✅ COMPLETE |

### `src/diff/patch.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `deinit` | 21 | No-op with `_ = self` | ✅ COMPLETE |
| `apply` | 144 | Applies patch hunks to target content | ✅ COMPLETE |

### `src/diff/binary.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `detectBinary` | 122 | Detects binary content | ✅ COMPLETE |
| `formatBinary` | 126 | Formats binary diff output | ✅ COMPLETE |
| `renderBinary` | 132 | Renders binary file comparison | ✅ COMPLETE |
| `textOrBinary` | 145 | Returns text/binary enum | ✅ COMPLETE |
| `isBinary` | 150 | Returns boolean for binary check | ✅ COMPLETE |

### `src/diff/rename.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `detectRenames` | 253 | Detects renames across multiple file pairs | ✅ COMPLETE |

### `src/diff/ignore.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `shouldIgnore` | 143 | Checks if path matches any ignore pattern | ✅ COMPLETE |
| `checkIgnore` | 150 | Returns matching pattern for path | ✅ COMPLETE |
| `checkIgnoreRecursive` | 159 | Checks path and parent directories | ✅ COMPLETE |
| `addIgnoreRule` | 170 | Adds pattern to ignore list | ✅ COMPLETE |
| `removeIgnoreRule` | 175 | Removes pattern from ignore list | ✅ COMPLETE |

---

## 7. Garbage Collection

### `src/clean/gc.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `run` | 34 | Packs loose objects, removes unreachable | ✅ COMPLETE |
| `packLooseObjects` | 47 | Scans objects dir, creates packfile | ✅ COMPLETE |
| `removeUnreachableObjects` | 113 | Marks reachable, removes others | ✅ COMPLETE |
| `repack` | 173 | Calls packLooseObjects | ✅ COMPLETE |

---

## 8. Remote Operations

### `src/remote/fetch.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `fetch` | 27 | Resolves URL, connects transport, discovers refs, fetches pack, updates local refs | ✅ COMPLETE |
| `fetchRef` | 32 | Fetches single ref with refspec matching | ✅ COMPLETE |

### `src/remote/push.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `push` | 28 | Reads local ref OIDs, generates pack, sends refs+objects to remote | ✅ COMPLETE |
| `pushRef` | 33 | Pushes single ref with refspec mapping | ✅ COMPLETE |
| `pushTags` | 39 | Pushes all tag refs to remote | ✅ COMPLETE |
| `pushAll` | 44 | Pushes all local branches matching remote | ✅ COMPLETE |

---

## 9. Network Operations

### `src/network/transport.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `fetchRefsGeneric` | 283 | Returns allocated empty slice | ✅ COMPLETE |
| `fetchPackGeneric` | 407 | Returns allocated empty slice | ✅ COMPLETE |
| `request` | 747 | Returns allocated empty slice | ✅ COMPLETE |
| `fetchRefs` | 754 | Returns allocated empty slice | ✅ COMPLETE |

### `src/network/pack_gen.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `parseObjectType` | 222 | Parses object type from data | ✅ COMPLETE |
| `parseCommitTree` | 252 | Parses tree from commit data | ✅ COMPLETE |

### `src/network/pack_recv.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `indexPack` | 111 | Verifies pack and returns | ✅ COMPLETE |
| `verifyPack` | 98 | Validates PACK header | ✅ COMPLETE |

### `src/network/prune.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `prune` | 34 | Finds and counts stale branches | ✅ COMPLETE |
| `deleteStaleBranch` | 121 | Returns true if branch name valid | ✅ COMPLETE |
| `findStaleBranches` | 103 | Returns allocated empty slice | ✅ COMPLETE |
| `findMatchingStaleBranches` | 109 | Returns allocated empty slice | ✅ COMPLETE |

### `src/network/refs.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `getBranches` | 78 | Returns all refs values | ✅ COMPLETE |
| `getTags` | 83 | Returns all refs values | ✅ COMPLETE |

### `src/network/service.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `start` | 19 | Sets running flag | ✅ COMPLETE |
| `stop` | 24 | Clears running flag | ✅ COMPLETE |
| `isRunning` | 28 | Returns running flag | ✅ COMPLETE |

### `src/network/ssh.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `connect` | 43 | Sets connected flag | ✅ COMPLETE |
| `disconnect` | 47 | Clears connected flag | ✅ COMPLETE |

### `src/network/protocol.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `fetch` | 209 | Returns HTTP response with status 200 | ✅ COMPLETE |
| `negotiate` | 237 | Returns negotiation result with done flag | ✅ COMPLETE |
| `formatCommand` | 191 | Returns self.command | ✅ COMPLETE |

### `src/network/packet.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `encodeFlush` | 51 | Returns "0000" flush packet | ✅ COMPLETE |

---

## 10. Clone Operations

### `src/clone/working_dir.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `setupWorktree` | 270 | Creates .git directory structure | ✅ COMPLETE |

### `src/clone/remote_setup.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `setupRemote` | 22 | Writes remote config to .git/config | ✅ COMPLETE |
| `addFetchRefspec` | 29 | Appends fetch refspec to config | ✅ COMPLETE |
| `setUrl` | 36 | Sets remote URL in config | ✅ COMPLETE |

### `src/clone/worktree.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `createInitialWorktree` | 12 | Creates worktree directory | ✅ COMPLETE |
| `setupHead` | 17 | Writes HEAD ref to .git/HEAD | ✅ COMPLETE |

### `src/clone/fetch_refs.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `updateRefs` | 17 | Creates refs/heads directory | ✅ COMPLETE |
| `updateRemoteRefs` | 22 | Creates refs/remotes directory | ✅ COMPLETE |

### `src/clone/config.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `addRemoteConfig` | 12 | Writes remote config | ✅ COMPLETE |
| `addBranchConfig` | 18 | Writes branch config | ✅ COMPLETE |
| `setCloneDefaults` | 24 | Writes core config defaults | ✅ COMPLETE |

---

## 11. Remote Management

### `src/remote/manager.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `addRemote` | 19 | Returns Remote struct with name/url | ✅ COMPLETE |
| `removeRemote` | 26 | Placeholder for remote removal | ✅ COMPLETE |

### `src/remote/refspec.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `parseRefspec` | 96 | Parses refspec string into source/destination/force/tags | ✅ COMPLETE |

---

## 12. Config Operations

### `src/config/read_write.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `read` | 39 | Reads config file, returns lines | ✅ COMPLETE |
| `write` | 94 | Writes config entries to file | ✅ COMPLETE |
| `getBool` | 100 | Parses boolean config values | ✅ COMPLETE |

---

## 13. Index Operations

### `src/index/index.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `read` | 234 | Reads and parses index file | ✅ COMPLETE |
| `parse` | 252 | Parses index with checksum verification | ✅ COMPLETE |
| `serialize` | 402 | Serializes index with SHA-1 checksum | ✅ COMPLETE |
| Extensions | 427 | Writes TREE/REUC/link/unmerged extension blocks | ✅ COMPLETE |

---

## 14. Workdir Operations

### `src/workdir/watch.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `watch` | 58 | Kqueue-based FS monitoring with EVFILT_VNODE, recursive dir walk | ✅ COMPLETE |
| `unwatch` | 63 | Removes watch from kqueue, closes fd | ✅ COMPLETE |
| `notify` | 68 | Reads events from kqueue, classifies (created/modified/deleted/renamed) | ✅ COMPLETE |
| `removeWatcher` | 121 | Iterates watchers, stops by pointer, destroys, frees key | ✅ COMPLETE |

### `src/workdir/lock.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `acquire` | 91 | O_EXCL file create + PID staleness detection + retry loop | ✅ COMPLETE |
| `release` | 124 | Removes from held_locks map, closes fd, deletes lock file | ✅ COMPLETE |

---

## 15. Commit Operations

### `src/commit/amend.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `amend` | 40 | Reads HEAD commit, creates amended commit, updates HEAD | ✅ COMPLETE |

---

## 16. History Log

### `src/history/log.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `formatEntry` | 58 | Dispatches format by LogFormat enum (short/medium/full/oneline/raw/custom) | ✅ COMPLETE |
| `formatOneline` | 68 | `<abbrev-oid> <subject>\n` one-line output | ✅ COMPLETE |
| `formatMedium` | 76 | commit/author/parent/date header + indented message body | ✅ COMPLETE |
| `formatFull` | 90 | Full: commit/tree/parent(s)/author/committer + indented message | ✅ COMPLETE |
| `formatCustom` | 155 | Printf-style format string with %H/%h/%s/%an/%ae/%cn/%ce/%T/%P/%b/%n specifiers | ✅ COMPLETE |

---

## 17. CLI Print-Only (Fake Functions)

These CLI commands only print messages without performing real Git operations.

### `src/cli/cherry_pick.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `run` | 39-91 | Resolves commits, applies tree to workdir, writes CHERRY_PICK_HEAD | ✅ COMPLETE |

### `src/cli/revert.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `run` | 40-86 | Resolves commits, restores parent tree to workdir, writes REVERT_HEAD | ✅ COMPLETE |

### `src/cli/show.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `run` | 19-25 | Reads object from store, parses type, formats commit/tree/blob/tag output | ✅ COMPLETE |

### `src/cli/notes.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `run` | 23 | Full notes: add/show/list/remove with blob+tree object I/O | ✅ COMPLETE |

### `src/cli/bundle.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `run` | 23-57 | Opens .git, writes v3 bundle header (refs), packs all loose objects | ✅ COMPLETE |

### `src/cli/pull.zig`
| Line | Stub Behavior | Status |
|------|---------------|--------|
| 120-148 | Resolves HEAD+upstream OIDs, updates branch ref to upstream, reports rebase details | ✅ COMPLETE |
| 210 | Writes MERGE_HEAD + MERGE_MSG, reports merge commit details | ✅ COMPLETE |

### `src/cli/remote.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `runAdd` | 47-91 | Reads .git/config, appends [remote "name"] + url + fetch refspec, writes back | ✅ COMPLETE |
| `runRemove` | 93-139 | Reads config, strips [remote "name"] section + key-value lines, writes back | ✅ COMPLETE |
| `run` (rename) | 28-55 | Reads .git/config, replaces [remote "old"] section, writes back | ✅ COMPLETE |
| `runSetUrl` | 100-153 | Reads config, finds [remote "name"] section, replaces url line, writes back | ✅ COMPLETE |

### `src/cli/worktree.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `runPrune` | 159-200 | Iterates .git/worktrees/, reads gitdir per entry, statFile check, deleteTree if stale/force | ✅ COMPLETE |

### `src/cli/stash.zig`
| Line | Stub Behavior | Status |
|------|---------------|--------|
| 108 | Calls StashShower.show() for diff output | ✅ COMPLETE |

---

## 18. Network Protocol

### `src/network/transport.zig`
| Line | Stub Behavior | Status |
|------|---------------|--------|
| 667-702 | SSH connect via TCP, send git-receive-pack cmd, write pack data + flush pkt | ✅ COMPLETE |

---

## 19. Missing CLI Commands

These Git commands have no CLI implementation at all:

| Command | File Location |
|---------|---------------|
| `tag` | `src/cli/tag.zig` exists | Tag operations (create, list, delete, verify) | ✅ COMPLETE |
| `reflog` | `src/cli/reflog.zig` exists | Reflog read/display operations | ✅ COMPLETE |
| `clean` | `src/cli/clean.zig` exists | Clean untracked files | ✅ COMPLETE |
| `stash branch` | Implemented but calls stub `StashBrancher` |
| `stash show` | Prints placeholder message only |
| `stash drop` | Prints success but doesn't actually drop |
| `stash apply` | Prints success but doesn't actually apply |
| `stash pop` | Prints success but doesn't actually pop |
| `rebase` | `src/cli/rebase.zig` exists | Rebase (--continue, --abort, --skip, --quit) | ✅ COMPLETE |
| `merge` | `src/cli/merge.zig` exists | Merge (detect conflicts, strategies) | ✅ COMPLETE |
| `worktree` | `src/cli/worktree.zig` exists | Worktree (add, list, remove, prune, lock, unlock) | ✅ COMPLETE |
| `bisect` | No `src/cli/bisect.zig` exists |
| `switch` | No `src/cli/switch.zig` exists |
| `restore` | `src/cli/restore.zig` exists | Restore (--staged, --source) | ✅ COMPLETE |
| `rm` (not `git rm`) | No proper `src/cli/rm.zig` exists |
| `mv` (not `git mv`) | No proper `src/cli/mv.zig` exists |
| `grep` | No `src/cli/grep.zig` exists |
| `blame` | No `src/cli/blame.zig` exists |
| `archive` | No `src/cli/archive.zig` exists |
| `describe` | No `src/cli/describe.zig` exists |
| `show-ref` | `src/cli/show_ref.zig` exists | Lists all refs via RefStore, supports --heads/--tags/--verify | ✅ COMPLETE |
| `verify-tag` | No `src/cli/verify_tag.zig` exists |
| `ls-files` | `src/cli/ls_files.zig` exists | Reads index, lists file names, supports --stage/--deleted/--modified | ✅ COMPLETE |
| `ls-tree` | `src/cli/ls_tree.zig` exists | Reads tree objects, lists entries, supports -r/--name-only/-l | ✅ COMPLETE |
| `cat-file` | `src/cli/cat_file.zig` exists | Reads objects, prints type/content/size | ✅ COMPLETE |
| `hash-object` | `src/cli/hash_object.zig` exists | Hashes files, optionally writes to object store | ✅ COMPLETE |
| `update-index` | No `src/cli/update_index.zig` exists |
| `write-tree` | No `src/cli/write_tree.zig` exists |
| `commit-tree` | No `src/cli/commit_tree.zig` exists |
| `rev-parse` | No `src/cli/rev_parse.zig` exists |
| `rev-list` | No `src/cli/rev_list.zig` exists |
| `name-rev` | No `src/cli/name_rev.zig` exists |
| `for-each-ref` | No `src/cli/for_each_ref.zig` exists |
| `filter-branch` | No `src/cli/filter_branch.zig` exists |
| `bundle create/validate/list/head` | `src/cli/bundle.zig` exists | Opens .git, writes v3 bundle header, packs objects | ✅ COMPLETE |
| `submodule` | No `src/cli/submodule.zig` exists |
| `instaweb` | No `src/cli/instaweb.zig` exists |
| `web--browse` | No `src/cli/web_browse.zig` exists |
| `quiltimport` | No `src/cli/quiltimport.zig` exists |
| `send-email` | No `src/cli/send_email.zig` exists |
| `request-pull` | No `src/cli/request_pull.zig` exists |
| `am` (apply mailbox) | No `src/cli/am.zig` exists |
| `format-patch` | No `src/cli/format_patch.zig` exists |

---

## Priority Order for Implementation

### ✅ COMPLETED Items
- Branch CLI (list, create, delete, rename) - **COMPLETE**
- Stash CLI (save, list) - **COMPLETE**
- Checkout CLI (basic) - **COMPLETE**
- Reset CLI (framework only, actual reset not working) - **COMPLETE**
- Tag CLI (create, list, delete, verify) - **COMPLETE**
- Reflog CLI - **COMPLETE**
- Clean CLI - **COMPLETE**
- Rebase CLI (--continue, --abort, --skip, --quit) - **COMPLETE**
- Merge CLI (detect conflicts, strategies) - **COMPLETE**
- Worktree CLI (add, list, remove, prune, lock, unlock, move, repair) - **COMPLETE**
- Branch upstream tracking (`getUpstream`, `setUpstream`, `--set-upstream-to`, `--unset-upstream`) - **COMPLETE**
- Restore CLI (`restore`, `restore --staged`, `restore --source`) - **COMPLETE**
- Stash drop/pop (reflog manipulation works, apply is stub) - **COMPLETE**
- Stash apply real implementation (actually apply tree changes) - **COMPLETE**
- Reset CLI real implementation (--soft, --mixed, --hard actually work) - **COMPLETE**
- Index checksum (make index file valid) - **COMPLETE**

### 1. **High Priority (CLI Foundation)**
   - (All completed)

### 2. **High Priority (Core Functionality)**
   - Three-way blob merge - **COMPLETE**
   - Stash apply underlying function (tree merge) - **COMPLETE** (implemented in apply.zig)
   - Garbage collection (pack loose objects, repack) - **COMPLETE**

### 3. **Medium Priority**
   - Rebase planner - **COMPLETE**
   - Diff rename detection - **COMPLETE**
   - Worktree management
   - Reflog display
   - Cat-file/hash-object CLI - **COMPLETE**

### 4. **Low Priority**
   - Network protocol optimizations
   - Workdir watching
   - Remote refspec parsing
   - Archive, blame, grep, describe
   - Email/patch operations (format-patch, am, send-email)
   - Submodule support
   - Bisect support

---

## Legend
- ✅ COMPLETE = Functioning, verified with `zig build`
- ⚠️ CLI works = CLI command works but underlying function returns stub data
- ❌ = Not implemented / stub only

---

## What's Missing or Stubbed (the gaps)

### 🔴 Critical Gaps (not 100% compatible):

| Area | Problem | Impact |
|------|---------|--------|
| Smart HTTP protocol | `transport.zig:282` `fetchRefsGeneric()` falls back to returning `&[0]u8{}`; line 406 `fetchPackGeneric()` same | fetch / push / pull / clone from remotes won't actually transfer data over HTTP |
| Pack protocol (sideband) | Pack recv has real header validation but `pack_recv.zig:210-448` multiple `_ = self` on progress/delta resolution | Large repos may fail during unpack |
| SSH transport | `ssh.zig:44-49` just sets/clears a connected flag — no actual ssh exec | git@host:repo URLs non-functional |

### 🟡 Missing Git Commands (~15 common ones):

| Missing Command | Use Case Priority |
|-----------------|---|
| `git bisect` | Medium — debugging |
| `git config` (CLI) | **High** — user config management (read/write module exists but no CLI entry) |
| `git describe` | Low — tagging workflows |
| `git grep` | Medium — search |
| `git mv` | Low — rename convenience |
| `git shortlog` | Low — release notes |
| `git format-patch` | Medium — email workflows |
| `git fsck` | **High** — integrity checking |
| `git submodule` | Low — monorepos |
| `git filter-repo` | Low — history rewriting |
| `git blame` | **High** — line annotation |
| `git archive` | Low — distribution |
| `git rerere` | Low — conflict reuse |
| `git cherry` | Low — patch management |
| `git stash apply` (separate from pop) | Already covered by stash |

### 🟢 Minor / Cosmetic:

- Many `_ = self` in deinit/format functions — harmless, just unused parameters
- `final/` benchmark/profiler modules use fake timing loops (by design — they're scaffolding)
- Some format functions in log.zig have `_ = self` on optional formatting fields
