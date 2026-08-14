## ADDED Requirements

### Requirement: Pane working-directory publication

When the `PATH_CLICK` knob is enabled (default), each rendered frame SHALL publish the pane's working directory (`cwd`) so that software outside Claude Code can resolve it. The record SHALL be written to `~/.claude/sl-cwd/<pid>` where `<pid>` is the process id of the claude process that owns the pane, and its content SHALL be the directory path.

The pid SHALL be obtained as the parent process id of the statusline command evaluated in the main shell, because that parent is the claude process, and because a subshell's own parent is the statusline script rather than claude. The statusline SHALL NOT attempt to record the pane's tty: Claude Code's child processes have no controlling terminal, so the tty is not observable on this side.

Publication SHALL run as a detached background job and SHALL NOT delay the frame being rendered. Publication SHALL use one file per pid rather than a shared file, so that concurrently rendering panes cannot lose each other's records and no lock is required. The directory and its records SHALL be created with owner-only permissions (700 and 600), because the map reveals the working directory of every open pane.

When `PATH_CLICK` is disabled, no record SHALL be written and the map directory SHALL NOT be created.

#### Scenario: a rendered frame publishes its directory
- **WHEN** a frame renders with `PATH_CLICK` enabled and `cwd` set
- **THEN** `~/.claude/sl-cwd/<claude pid>` SHALL exist and contain that `cwd`
- **AND** the directory SHALL be mode 700 and the record mode 600

#### Scenario: the knob disables publication entirely
- **WHEN** a frame renders with `PATH_CLICK` disabled
- **THEN** no record SHALL be written

### Requirement: Reaping records of panes that are gone

Each publication SHALL remove records whose pid no longer belongs to a running process, so the map cannot grow without bound. Liveness SHALL be determined by enumerating running processes rather than by signalling each pid, because signalling a process owned by another user fails with a permission error that is indistinguishable from the process being absent, which would delete the record of a pane that is still alive. Files whose name is not a plain pid SHALL be left untouched.

#### Scenario: dead pane record is removed, live one is kept
- **GIVEN** the map holds a record for a pid that is not running, a record for a running process the user does not own, and a file whose name is not numeric
- **WHEN** a frame renders
- **THEN** only the record for the pid that is not running SHALL be removed

### Requirement: Terminal-side directory opener

The project SHALL provide an opener that a terminal can invoke on a click and that resolves a pane's tty to the directory published for that pane, then opens it with the platform's file manager.

The opener SHALL accept the tty as its argument and, when no argument is given, SHALL ask the terminal for the frontmost session's tty, which is the pane a click has just focused. It SHALL reject any tty argument that is not a plain device name before using it. It SHALL locate the claude processes attached to that tty and use the most recently written published record among them, because nested sessions place more than one claude process on a single tty. It SHALL NOT open anything when no record can be resolved or when the recorded directory no longer exists.

Because the invoking terminal action discards the opener's standard output and error, failures SHALL be reported through a desktop notification, and that notification SHALL be suppressible so automated tests can exercise the failure paths silently.

#### Scenario: click resolves to the pane's directory
- **GIVEN** a pane whose claude process is attached to a tty and whose directory has been published
- **WHEN** the opener is invoked with that tty
- **THEN** it SHALL open the published directory and exit successfully

#### Scenario: unknown pane does not open anything
- **WHEN** the opener is invoked with a tty that has no published record
- **THEN** it SHALL exit unsuccessfully without opening any directory

#### Scenario: malformed tty argument is rejected
- **WHEN** the opener is invoked with a tty argument that is not a plain device name, such as one containing path traversal
- **THEN** it SHALL reject the argument and exit unsuccessfully without consulting the process table
