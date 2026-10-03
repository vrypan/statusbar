# Keep a user's existing sb command, alias or function.
if ! whence -w sb >/dev/null 2>&1; then
  alias sb=@COMMAND@
fi
