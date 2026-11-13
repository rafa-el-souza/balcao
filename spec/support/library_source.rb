# The source of a library's method as its file has it, dedented, for the
# specs that pin a method of Action Cable an override relies on (ADR-0015):
# when Rails changes it, the pin breaks and the override is read again.
module LibrarySource
  def source_of(owner, name)
    file, line = owner.instance_method(name).source_location
    lines = File.readlines(file).drop(line - 1)
    indent = lines.first[/\A */]
    lines.take(lines.index { _1 == "#{indent}end\n" } + 1).map { _1.delete_prefix(indent) }.join
  end
end
