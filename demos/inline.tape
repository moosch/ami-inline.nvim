# ami-inline — comment-driven FIM completion
#
# Record with:  vhs demos/inline.tape
# Needs `vhs` + a running LM Studio, and ami core checked out next to this repo
# (../ami.nvim or ../ai-harness, or set $AMI_CORE). Set $AMI_ENDPOINT if LM Studio
# isn't on localhost. Tune the Sleep after Ctrl+G to your model's latency.

Output demos/inline.gif

Require nvim
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 20
Set Framerate 24
Set TypingSpeed 55ms
Set Theme "Catppuccin Mocha"

# --- setup (hidden): write a small source file and open it ---
# \042 is printf's octal for a double quote; %% prints a literal %.
Hide
Type "printf 'package store\n\nimport (\n\t\042context\042\n\t\042database/sql\042\n\t\042errors\042\n\t\042fmt\042\n)\n\nvar ErrNotFound = errors.New(\042store: user not found\042)\n\n// Get loads one user by id, returning ErrNotFound when the row is absent.\nfunc Get(ctx context.Context, db *sql.DB, id string) (*User, error) {\n\trow := db.QueryRowContext(ctx, \042SELECT id, name, email FROM users WHERE id = $1\042, id)\n\tvar u User\n\tif err := row.Scan(&u.ID, &u.Name, &u.Email); err != nil {\n\t\treturn nil, fmt.Errorf(\042store.Get(%%q): %%w\042, id, err)\n\t}\n\treturn &u, nil\n}\n' > /tmp/ami_inline_demo.go"
Enter
Type "nvim -u demos/init.lua /tmp/ami_inline_demo.go"
Enter
Sleep 3s
Show
Sleep 1s

# --- start a new function from a comment at the end of the file ---
Type "G"
Type "o"
Enter
Type "// Delete removes the user with the given id, returning ErrNotFound if absent."
Enter
Sleep 1s

# --- request a completion; wait for the ghost text ---
Ctrl+G
Sleep 6s

# --- accept it ---
Tab
Sleep 2s
Escape
Sleep 2500ms
