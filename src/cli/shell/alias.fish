# Keep a user's existing sb command, alias or function.
if not type -q sb
  alias sb @COMMAND@
end
