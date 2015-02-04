A simple (hackish) ruby meta-shell-script that connects to a server, creates a git repo, and creates a post-update hook.

Said post-update hook will create a satellite of of the repo after push, and then run a script inside of that repo duplicate.

This was written as a not-lazy-solution to the lazy problem of needing to test each program in my uni's CS course on their server.

