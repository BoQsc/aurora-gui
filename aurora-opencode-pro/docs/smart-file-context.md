# Smart File Context

One feature, enabled by default in Settings. Its switch controls the agent's
absolute-link instruction, reference metadata, folder inference and additional
context-menu actions. Turning it off preserves existing metadata and history.

The transcript keeps its original text. Each message gets a captured absolute
base and a mapping from file mentions to absolute targets, including bare
filenames, quoted paths with spaces, file URLs and structured tool arguments.
Line/column suffixes are removed from filesystem targets. Normal web URLs keep
their original destinations. Unrecognised prose is accepted only when it names
an existing entry in the captured workspace. Old messages keep their targets
when the conversation moves to another project.

Right-click a reference to open its file/folder or copy its absolute path.
Missing files retain their path metadata and can reveal an existing parent.
Right-click a conversation for **Open main folder**, **Copy main folder path**,
**Choose main folder…**, **Re-detect main folder**, and ranked candidates when
more than one folder is used. The existing **Open folder** uses the same target.

Main-folder detection groups files at the nearest Git root, weights structured
tool paths three times as strongly as prose, and counts a folder once per
message. Only the active history branch contributes. A tie falls back to the
conversation's workspace and leaves the candidate choices available. A manual
choice stays pinned until Re-detect. These actions never change the tools' cwd.
Unloaded sidebar rows use persisted evidence without loading full transcripts.

Sidecars live in `%APPDATA%/Aurora OpenCode/file-context/`, keyed by a hash of the
conversation id. They are optional and independent of the conversation schema.
Snapshots use the existing persistence worker; rendering does not write files.
Legacy history is enriched when loaded. Metadata cannot reconstruct the original
workspace of old references that predates this feature; its initial base is the
conversation's workspace at the time it is first enriched.

Removal: delete `source/auroraopencode/filecontext.d` and every
`filecontext:begin` through `filecontext:end` region in `appui.d` and the core's
`core.d`. Optional sidecars may be retained or deleted. Verify with
`python tools/check-filecontext-removal.py`, which compiles a stripped temporary
source tree. No tools, orchestrator or execution-policy changes are required.

Behavior/UI verification:
`python tests/run_architecture_checks.py file_context_contracts`.
