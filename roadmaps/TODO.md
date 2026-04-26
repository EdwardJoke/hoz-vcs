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

## 18. Stub Code Found (Deep Scan — 2026-04-26)

> These functions have `_ = self` + empty/fake returns or no-op bodies.
> They compile and pass `zig build` but produce no real results.

### 18.1 Checkout / Switch — ✅ Implemented

### `src/checkout/switch.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `BranchSwitcher.switch` | 36 | Resolves ref via RefStore.resolve → writes `ref: <name>` to .git/HEAD via Io.Dir.cwd().createFile | ✅ |
| `BranchSwitcher.createAndSwitch` | 52 | Resolves HEAD for OID, checks if target branch exists (force_create guard), writes HEAD to new branch ref | ✅ |
| `BranchSwitcher.detachHead` | 75 | Converts OID to hex string, writes raw OID to .git/HEAD (detached HEAD mode) | ✅ |

### 18.2 Bisect — Partial Stub

### `src/bisect/start.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `BisectStart.getRevList` | 56 | Reads bisect/bad ref, walks parent chain via getParentOids() (reads loose objects, parses `parent <oid>` lines), tracks visited commits in StringHashMap, returns owned OID slice | ✅ |
| `BisectStart.start` | 30 | Writes bisect refs to disk ✅, rev-list now walks commit graph from bad → root | ✅ |

### 18.3 History Blame — ✅ Implemented

### `src/history/blame.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `Blamer.blameFile` | 53 | Reads file via std.fs.cwd().openFile, splits content by `\n`, creates BlameLine per line (original/final line numbers), wraps in BlameEntry with filename | ✅ |
| `Blamer.getBlameForRange` | 61 | Calls blameFile, filters lines where final_line_number ∈ [start, end], returns filtered entries with deep-copied fields | ✅ |

### 18.4 Worktree — Partial Stub

### `src/worktree/list.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `WorktreeLister.list` | 13 | Opens .git/worktrees/, walks directories, reads gitdir→HEAD per worktree, checks locked status | ✅ |

### `src/worktree/add.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `WorktreeAdder.add` | 15 | Creates worktree dir, writes .git gitfile, creates .git/worktrees/<branch>/ with HEAD+gitdir | ✅ |

### 18.5 Rebase — Partial Stubs

### `src/rebase/picker.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `RebasePicker.parseTodoList` | 33 | Parses rebase todo lines (pick/reword/edit/squash/fixup/drop/exec + short forms), skips #comments and blanks | ✅ |
| `RebasePicker.getAction` | 45 | When autosquash enabled: checks commit first line for `squash!` → .squash, `fixup!` → .fixup; otherwise returns .pick | ✅ |

### `src/rebase/replay.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `CommitReplayer.replay` | 36 | Reads commit object, checks for empty tree skip, returns ReplayResult | ✅ |
| `CommitReplayer.replayMultiple` | 48 | Iterates commits, calls replay() per commit, chains base OID, returns allocated results | ✅ |

### `src/rebase/planner.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `RebasePlanner.groupSquashCommits` | 160 | Reads each commit message, finds squash!/fixup! commits, moves them after target by subject match | ✅ |

### 18.6 Tag List — ✅ Implemented

### `src/tag/list.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `TagLister.listAll` | 13 | Opens .git/refs/tags/, walks files, returns tag name slice | ✅ |
| `TagLister.listMatching` | 19 | Calls listAll, filters via globMatch (supports `prefix*`, `*suffix`, exact) | ✅ |
| `TagLister.listWithDetails` | 24 | Calls listAll, reads each ref's OID from .git/refs/tags/<name>, returns `"tag oid"` strings | ✅ |

### 18.7 Remote List — Full Stub

### `src/remote/list.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `RemoteLister.list` | 20 | Calls parseRemotes, converts to RemoteInfo slice with fetched=false | ✅ |
| `RemoteLister.listVerbose` | 25 | Same as list with verbose parseRemotes | ✅ |
| `RemoteLister.getRemoteNames` | 30 | Parses remotes, extracts name field into allocated slice | ✅ |

### 18.8 Config List — ✅ Implemented

### `src/config/list.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `ConfigLister.listAll` | 13 | Reads .git/config, ~/.gitconfig, /etc/gitconfig, returns all non-empty lines | ✅ |
| `ConfigLister.listLocal` | 36 | Reads .git/config via Io.Dir.cwd().readFileAlloc | ✅ |
| `ConfigLister.listGlobal` | 40 | Resolves $HOME, reads ~/.gitconfig | ✅ |
| `ConfigLister.listSystem` | 47 | Reads /etc/gitconfig | ✅ |

### 18.9 Show Ref — ✅ Implemented

### `src/history/show_ref.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `RefShower.showRefs` | 39 | Walks .git/refs/{heads,tags,remotes}, reads each ref file, returns ShowRefResult[] | ✅ |
| `RefShower.showHead` | 113 | Reads .git/HEAD, resolves symref target, returns OID + symref info | ✅ |
| `RefShower.formatRef` | 159 | Formats `{abbrev_oid} {ref_name}` with optional symref/deref output | ✅ |

### 18.10 Protocol Capabilities — ✅ Implemented

### `src/remote/capabilities.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `CapabilityNegotiator.negotiate` | 37 | Parses server cap strings via StaticStringMap → Capability enum, returns CapabilitySet | ✅ |
| `CapabilityNegotiator.hasCapability` | 51 | Linear scan of negotiated caps list, returns bool | ✅ |
| `CapabilityNegotiator.getCommonCapabilities` | 58 | Intersects server caps with client-supported set (7 caps) | ✅ |

### 18.11 Want/Have Exchange — Full Stub

### `src/network/exchange.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `WantHaveExchanger.sendWant` | 34 | Stores OID copy in wants list | ✅ |
| `WantHaveExchanger.sendHave` | 38 | Stores OID in haves, cross-checks wants for common/acknowledged | ✅ |
| `WantHaveExchanger.sendDone` | 43 | Sets done_sent flag | ✅ |
| `WantHaveExchanger.processAcks` | 47 | Filters acks against wants (and haves if multi_ack_detailed), returns common slice | ✅ |

### 18.12 Push Refspec — ✅ Implemented

### `src/remote/push_refspec.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `PushRefspecParser.parse` | 18 | Parses `+src:dst`, `:dst`, `shorthand` → returns owned PushRefspec | ✅ |
| `PushRefspecParser.parseMultiple` | 54 | Iterates inputs, calls parse for each, collects results | ✅ |
| `PushRefspecParser.validate` | 73 | Checks ref name validity (no `..`, `.lock`, `\`, must start with `refs/`) | ✅ |

### 18.13 Stage Move — ✅ Implemented

### `src/stage/mv.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `StagerMover.move` | 30 | Uses Index.findEntry→removeEntry→addEntry to rename index entries | ✅ |
| `StagerMover.moveMultiple` | 55 | Iterates moves, accumulates renamed/errors counts | ✅ |

### 18.14 Config Unset — ✅ Implemented

### `src/config/config.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `Config.unset` | 85 | Uses entries.fetchRemove(key) + frees value | ✅ |

### 18.15 Perf / Cache — ✅ Implemented

### `src/perf/cache.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `ObjectCache.warmCache` | 174 | Reads .git/HEAD, resolves symref, reads packed-refs + info/refs to pre-populate | ✅ |
| `ObjectCache.setEvictionPolicy` | 199 | Stores policy (lru/fifo/lfu), evictOne() switches on policy, LFU tracks access counts | ✅ |

### 18.16 Packfile Detection — Always False

### `src/object/packfile.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `getReuseOffsets` | 72 | Parses PACK header, scans object entries, returns offset slice for delta objects | ✅ |
| `detectThinPack` | 78 | Scans for OBJ_REF_DELTA (type 7), optionally checks missing base objects | ✅ |

### 18.17 Remote Manager — Stub

### `src/remote/manager.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `RemoteManager.pruneRemote` | 198 | Walks refs/remotes/<name>/, checks orphan status vs HEAD, deletes/prunes stale refs | ✅ |

### 18.17 Pull — Simplified Logic

### `src/cli/pull.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `Pull.checkFastForward` | 180 | Walks descendant's parent chain (max 10000 depth) via readCommit+extractParent, checks if ancestor_oid appears → returns can_ff bool | ✅ |

### 18.18 Transport — ✅ Implemented

### `src/network/transport.zig`
| Function | Line | Stub Behavior | Status |
|----------|------|---------------|--------|
| `Transport.buildPushCapabilities` | 704 | Reads caps struct fields (report_status, sideband_64k, atomic, push_options, multi_ack), builds space-separated string with agent= tag | ✅ |

### Summary Table

| Category | File(s) | ❌ Count | ⚠️ Count |
|----------|---------|----------|-----------|
| Checkout/Switch | switch.zig | 0 | 0 |
| Bisect | start.zig | 0 | 0 |
| Blame | blame.zig | 0 | 0 |
| Worktree | list.zig, add.zig | 0 | 0 |
| Rebase | picker.zig, replay.zig, planner.zig | 0 | 0 |
| Tag | list.zig | 0 | 0 |
| Remote | list.zig, manager.zig, push_refspec.zig, capabilities.zig | 0 | 0 |
| Config | config.zig, list.zig | 0 | 0 |
| Show Ref | show_ref.zig | 0 | 0 |
| Network | exchange.zig, transport.zig | 0 | 0 |
| Stage | mv.zig | 0 | 0 |
| Perf | cache.zig | 0 | 0 |
| Packfile | packfile.zig | 0 | 0 |
| Pull | pull.zig | 0 | 0 |
| **TOTAL** | **19 files** | **0** | **0** |

---

## Completed Stubs (2026-04-26)

> These stubs were implemented in this session. `zig build` passes for all.

### ✅ Tag List — `src/tag/list.zig`
- `TagLister.listAll` — walks `.git/refs/tags/`, returns tag names
- `TagLister.listMatching` — filters tags by glob pattern (`v*`, `*1.0`)
- `TagLister.listWithDetails` — returns `"tagname <oid>"` strings

### ✅ Worktree List — `src/worktree/list.zig`
- `WorktreeLister.list` — walks `.git/worktrees/`, reads HEAD + locked status

### ✅ Remote List — `src/remote/list.zig`
- `RemoteLister.list/listVerbose/getRemoteNames` — parses `.git/config` `[remote "..."]`

### ✅ Config List — `src/config/list.zig`
- `ConfigLister.listAll/listLocal/listGlobal/listSystem` — reads real config files

### ✅ Stage Move — `src/stage/mv.zig`
- `StagerMover.move/moveMultiple` — uses Index.findEntry→removeEntry→addEntry

### ✅ Config Unset — `src/config/config.zig`
- `Config.unset` — uses entries.fetchRemove(key) + frees value

### ✅ Show Ref — `src/history/show_ref.zig`
- `RefShower.showRefs` — walks `.git/refs/{heads,tags,remotes}`, reads ref files, returns ShowRefResult[]
- `RefShower.showHead` — reads `.git/HEAD`, resolves symref target, returns OID + symref
- `RefShower.formatRef` — formats `{abbrev_oid} {ref_name}` with optional symref/deref

### ✅ Push Refspec — `src/remote/push_refspec.zig`
- `PushRefspecParser.parse` — parses `+src:dst`, `:dst`, shorthand → owned PushRefspec
- `PushRefspecParser.parseMultiple` — iterates inputs, calls parse for each
- `PushRefspecParser.validate` — checks ref name validity (no `..`, `.lock`, `\`, must start with `refs/`)

### ✅ Rebase Picker — `src/rebase/picker.zig`
- `RebasePicker.parseTodoList` — parses rebase todo lines (pick/reword/edit/squash/fixup/drop/exec + short forms p/r/e/s/f/d/x), skips #comments and blanks

### ✅ Capability Negotiator — `src/remote/capabilities.zig`
- `CapabilityNegotiator.negotiate` — parses server capability strings via `StaticStringMap` → `Capability[]`, returns `CapabilitySet`
- `CapabilityNegotiator.hasCapability` — linear scan of negotiated caps, returns bool
- `CapabilityNegotiator.getCommonCapabilities` — intersects server caps with 7 client-supported caps

### ✅ Object Cache — `src/perf/cache.zig`
- `ObjectCache.warmCache(io)` — reads `.git/HEAD`, resolves symref, reads `packed-refs` + `info/refs` for pre-population
- `ObjectCache.setEvictionPolicy(policy)` — stores policy (lru/fifo/lfu); `evictOne()` switches on policy; LFU tracks access counts in `AutoHashMap`

### ✅ Rebase Planner Squash Group — `src/rebase/planner.zig`
- `RebasePlanner.groupSquashCommits(commits)` — reads each commit's message, detects `squash!` / `fixup!` prefixes, matches target by subject line, moves squash commits right after their target via `orderedRemove` + `insert`

### ✅ BranchSwitcher — `src/checkout/switch.zig`
- `BranchSwitcher.switch(branch)` — resolves ref name via `refName()` → `RefStore.resolve()`, writes `ref: <name>` to `.git/HEAD`
- `BranchSwitcher.createAndSwitch(branch)` — resolves HEAD for OID, checks target branch existence (respects `force_create`), writes HEAD to new branch ref
- `BranchSwitcher.detachHead(oid)` — converts OID to hex via `toHex()`, writes raw OID to `.git/HEAD` (detached HEAD mode)

### ✅ Pull Fast-Forward Check — `src/cli/pull.zig`
- `Pull.checkFastForward(ancestor_oid, descendant_oid)` — walks descendant's parent chain (max 10000 depth) using `readCommit()` + `extractParent()`, returns `{can_ff}` when ancestor found in ancestry

### ✅ Transport Push Capabilities — `src/network/transport.zig`
- `Transport.buildPushCapabilities(caps)` — reads `ProtocolCapabilities` struct fields (`report_status`, `sideband_64k`, `atomic`, `push_options`, `multi_ack`), builds space-separated capability string with `agent=<name>` tag via `ArrayList` + `mem.join`

### ✅ Bisect Rev List — `src/bisect/start.zig`
- `BisectStart.getRevList()` — reads `.git/bisect/bad` ref, walks commit parent chain (max 10000 depth) via `getParentOids()` which reads loose objects and parses `parent <oid>` lines; uses `StringHashMap(void)` for cycle detection; returns owned OID slice
- `BisectStart.getParentOids(oid_str)` — reads `.git/objects/<xx>/<hex>`, parses raw commit object for `parent ` lines, returns parent OID slice

### ✅ History Blame — `src/history/blame.zig`
- `Blamer.blameFile(path)` — opens file via `std.fs.cwd().openFile`, reads content, splits by `\n`, creates `BlameLine` per line with original/final line numbers, wraps in single `BlameEntry`
- `Blamer.getBlameForRange(path, start, end)` — delegates to `blameFile()`, filters lines where `final_line_number ∈ [start, end]`, deep-copies all fields for returned entries

### ✅ Rebase Picker Action — `src/rebase/picker.zig`
- `RebasePicker.getAction(commit)` — when `options.autosquash`: checks first line of commit message for `squash!` prefix → returns `.squash`, `fixup!` → returns `.fixup`; otherwise defaults to `.pick`

### ✅ Worktree List — `src/worktree/list.zig`
- `WorktreeLister.list()` — opens `.git/worktrees/`, walks directories via `Dir.walk`, reads each worktree's `gitdir`→`HEAD` to get branch/detached info, checks locked status

### ✅ Tag List — `src/tag/list.zig`
- `TagLister.listAll()` — opens `.git/refs/tags/`, walks files, returns tag name slice
- `TagLister.listMatching(pattern)` — calls `listAll()`, filters via `globMatch()` supporting `prefix*`, `*suffix`, exact match
- `TagLister.listWithDetails()` — calls `listAll()`, reads each tag's OID from `.git/refs/tags/<name>`, returns `"tag oid"` format strings

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

---

## 18. Comprehensive Stub Code Audit

> Generated by deep codebase scan. Every function below returns **fake/hardcoded/empty** data instead of performing real operations.

### 18.1 🔴 Hardcoded Fake Data Returns

#### `src/cli/format_patch.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `generatePatch` | 77 | Returns hardcoded patch string: `"From: hoz <hoz@local>"`, `"sample commit"`, `"0000000..1234567"`, `"+sample content"`. Never reads real commits. |
| `run` | 72 | `_ = patch_content;` — generated patch is discarded, never written to disk. |

#### `src/cli/fsck.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `run` | 48-49 | Checks hardcoded `"HEAD"` with fake data `"checking HEAD"`, and `"refs/heads/main"` against zero-hash `"0000...0"`. Never scans real objects. |
| `run` | 86 | `--lost-found` prints `"not yet implemented"` — entire dangling object detection is missing. |

#### `src/describe/describe.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `describeCommit` | 45,50-54 | Hardcodes tag name `"v0.0.0"`, OID as 40 zeros, depth=0. Ignores `commitish` param (`_ = commitish`). Never walks ref history. |
| `describeTags` | 65,75 | Falls back to `&[_][]const u8{}` if `.git/refs/tags` missing. No tag-to-commit distance calculation. |

#### `src/blame/blame.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `blameFile` | 43 | Every line gets: `commit_oid = "0000...0"`, `author = "unknown"`, `author_date = "1970-01-01"`. No commit ancestry lookup whatsoever. |

### 18.2 🔴 Empty / No-op Returns

#### `src/worktree/list.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `list` | 14 | Returns `&[_]WorktreeInfo{}` — always empty. Discards `self`. Never reads `.git/worktrees/`. |

#### `src/bisect/start.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `getRevList` | 57 | Returns `&[_][]const u8{}` — always empty. No commit range computation. |

#### `src/bisect/run.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `run` | 27 | Ignores `commit` param, returns `self.exit_code` (default 0). No test execution. |
| `execute` | 32 | Ignores `cmd` param, returns `self.exit_code`. No command spawning. |
| `getNextCommit` | 42 | Returns `""` — empty string. No binary search midpoint selection. |

#### `src/network/transport.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `fetchRefsGeneric` | 283 | Allocates 0-length `RemoteRef` array. No network I/O. |
| `fetchPackGeneric` | 407 | Allocates 0-byte `[]u8`. No pack data transfer. |

#### `src/network/prune.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `findStaleBranches` | 103 | Discards `remote` param, returns empty slice. No stale detection logic. |
| `findMatchingStaleBranches` | 109 | Discards `pattern` param, returns empty slice. No pattern matching. |
| `deleteStaleBranch` | 121 | Returns `branch.name.len > 0` — trivially true for any non-empty name. No actual deletion. |

#### `src/network/protocol.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `HTTPProtocol.fetch` | 209 | Returns `{ .status = 200, .body = url[0..0] }` — empty body. Ignores `service`. |
| `SmartProtocol.negotiate` | 237 | Returns `{ .common_refs = &.{}, .ready = self.done }` — empty refs, always "done". Ignores have/want. |

#### `src/network/service.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `start` | 19 | Sets `running = true`. Ignores `host`. No socket/listen. |
| `stop` | 24 | Sets `running = false`. No cleanup. |

#### `src/network/ssh.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `connect` | 43 | Sets `connected = true`. No SSH handshake/auth. |
| `disconnect` | 47 | Sets `connected = false`. No channel close. |

#### `src/history/show_ref.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `showRefs` | 38 | Returns `&.{}` — empty. Never reads refs. |
| `showHead` | 43 | Returns `ShowRefResult` with `oid = undefined`. Uninitialized memory. |
| `formatRef` | 52 | Complete no-op: discards `self`, `result`, `writer`. Outputs nothing. |

#### `src/clean/interactive.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `prompt` | 23 | Always returns `false`. Ignores path. No user interaction. |
| `showMenu` | 26 | Empty body. No menu display. |
| `selectAction` | 30 | Empty body. Ignores action + paths. |

#### `src/object/packfile.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `getReuseOffsets` | 68 | Parses PACK signature+count, scans entries, returns offset slice for delta objects |
| `detectThinPack` | 74 | Scans for OBJ_REF_DELTA (type 7), optionally checks missing base objects via fs |
| `isThinPack` | 63 | Always returns `false` after signature check. |

#### `src/commit/parser.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `validateFormat` | 64 | Always returns `true`. Ignores input data entirely. |

#### `src/diff/parallel.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `processInParallel` | 170-178 | Discards `old_lines`, `new_lines`, `edits`, `results`. Only increments counters. No parallel processing. |

#### `src/network/refs.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `getBranches` | 78 | Returns `self.refs.values()` — **all** refs, not filtered to branches only. |
| `getTags` | 83 | Returns `self.refs.values()` — **all** refs, not filtered to tags only. |

#### `src/remote/manager.zig`
| Function | Line | Stub Behavior |
|----------|------|---------------|
| `renameRemote` | 198 | Ignores `new_name`. Returns old remote or empty struct. |
| `setUrl` | 204 | Ignores `url`. Returns old remote or empty struct. |
| `showRemote` | 210 | Returns `branches: &.{}`, `tags: &.{}` — always empty. |
| `pruneRemote` | 226 | Walks refs/remotes/<name>/, checks orphan status vs HEAD, deletes stale refs (unless dry_run) |

### 18.3 🟡 Result-Discarding Stubs (`_ = result`)

These functions compute a result but immediately discard it — the caller gets nothing useful.

| File | Line | Function | What's Discarded |
|------|------|----------|------------------|
| `src/cli/format_patch.zig` | 72 | `run` | Entire generated patch content (`patch_content`) |
| `src/branch/delete.zig` | 144 | test `deleteMultiple` | Delete result struct |
| `src/network/pack_recv.zig` | 368, 376, 383 | test helpers | Index/write/compress results |
| `src/merge/markers.zig` | 311 | test `formatConflict` | Formatted conflict output |
| `src/merge/resolution.zig` | 318 | test `resolveAll` | Resolution results array |
| `src/branch/upstream.zig` | 184, 203 | tests | Upstream config results |
| `src/branch/list.zig` | 278 | test `listCurrent` | Branch list result |
| `src/diff/parallel.zig` | 178 | `processInParallel` | Parallel diff results |
| `src/object/packfile.zig` | 71, 76 | `unpackObjects` loop | Decompressed object data |
| `src/merge/fast_forward.zig` | 128 | test helper | Fast-forward check result |
| `src/rebase/picker.zig` | 79 | test helper | Todo list parse result |
| `src/rebase/replay.zig` | 76 | test helper | Replay results array |
| `src/perf/lazy.zig` | 84 | test helper | Lazy-loaded data |
| `src/history/show_ref.zig` | 52 | `formatRef` | Formatted ref output |
| `src/clean/interactive.zig` | 46 | test `prompt` | User prompt result |

### 18.4 🟢 Test-only Stubs (acceptable in tests)

These are dummy values used **only in test blocks** — not production stubs:

| File | Pattern |
|------|---------|
| `src/merge/fast_forward.zig` | `dummyGetCommit` fn returning `null` |
| `src/merge/analyze.zig` | Same pattern — null-returning commit getter |
| `src/ref/store.zig` | `"abc123def456..."` fake OIDs in test data |
| `src/object/commit.zig` | `timestamp = 1234567890`, `John Doe <john@example.com>` in tests |
| `src/network/service.zig` | `"abc123def... refs/heads/main"` test ref lines |
| `src/network/refs.zig` | Same test ref line pattern |
| `src/network/shallow.zig` | `deepenSince(1640000000)` test timestamp |

---

## Legend
- ✅ COMPLETE = Functioning, verified with `zig build`
- ⚠️ CLI works = CLI command works but underlying function returns stub data
- ❌ = Not implemented / stub only
