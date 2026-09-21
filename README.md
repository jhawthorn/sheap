# Sheap

Sheap is a library for interactively exploring Ruby Heap dumps. Sheap contains a command-line tool and a library for use in IRB.

Some examples of things you can do with Sheap:
- Find all retained objects between two heap dumps, and analyze them by their properties
- Inspect individual objects in a heap dump, and interrogate the objects it references and the objects that reference it (reverse references)
- For a given object, discover all paths back to the root of the heap, which can help you understand why an object is retained.

Why Ruby heap dumps, briefly:
- Ruby heap dumps are a snapshot of the state of the Ruby VM at a given point in time, which can be useful for understanding memory-related behavior such as bloat and retention issues.
- The heap contains objects that may be familiar to your application (constants, classes, instances of classes, and primitives like strings and arrays), as well as objects that are internal to the Ruby VM, such as instruction sequences and call caches.
- Ruby's garbage collector is a mark-and-sweep collector, which means that it starts at the root of the heap and marks all objects that are reachable from the root. It then sweeps the heap, freeing any objects that were not marked. This means that any object that is reachable from the root is retained, and any object that is not reachable from the root is freed. This is why it's useful to find all objects that are retained between two heap dumps (and thus multiple GC runs), inspect their properties, and understand their paths back to the root of the heap.

## Installation

You can `gem install sheap` to get sheap as a library and command line tool. You can also download `lib/sheap.rb` to a remote server and require it as a standalone file from IRB.

## Usage

Using the command line will open an IRB session with the heap loaded. You can then use the `$diff`, `$before`, `$after` (and an optional `$later` variable for 3-way diffs) to explore the heap.

```console
$ sheap [HEAP_BEFORE.dump] [HEAP_AFTER.dump] [HEAP_LATER.dump]
```

To use directly with IRB:

```ruby
# $ irb

require './lib/sheap'

# Create a diff of two heap dumps
$diff = Sheap::Diff.new('tmp/heap_before.dump', 'tmp/heap_after.dump')

# Find all retained objects and count by type
$diff.retained.map(&:type_str).tally.sort_by(&:last)
# => [["DATA", 1], ["FILE", 1], ["IMEMO", 4], ["STRING", 4], ["ARRAY", 10000]]

# Find the 4 largest arrays in the 'after' heap dump
>> $diff.after.arrays.sort_by(&:length).last(5)
# =>
# [#<ARRAY 0x100ec0440  (512 refs)>,
#  #<ARRAY 0x100ec9270  (512 refs)>,
#  #<ARRAY 0x100f4b450  (512 refs)>,
#  #<ARRAY 0x11bc6d5b0  (512 refs)>,
#  #<ARRAY 0x11c137960  (10000 refs)>]

# Grab and examine just the largest array
large_arr = $diff.after.arrays.max_by(&:length)
# =>
# #<ARRAY 0x1023effc8
#  type="ARRAY",
#  shape_id=0,
#  slot_size=40,
#  class=#<CLASS 0x100e43350 Array (252 refs)>,
#  length=10000,
#  references=(10000 refs),
#  memsize=89712,
#  flags=wb_protected>

# Is it old?
large_arr.old?
# => false

# Find the first of its references
large_arr.references.first
# =>
# #<ARRAY 0x11c13fdb8
#  type="ARRAY",
#  shape_id=0,
#  slot_size=40,
#  class=#<CLASS 0x100e43350 Array (252 refs)>,
#  length=0,
#  embedded=true,
#  memsize=40,
#  flags=wb_protected>

# Reference that same object by address
$diff.after.at("0x11c13fdb8")
# =>
# #<ARRAY 0x11c13fdb8
#  type="ARRAY",
#  ...

# Show that object's path back to the root of the heap
$diff.after.find_path($diff.after.at("0x11c13fdb8"))
# => [#<ROOT global_tbl (13 refs)>, #<ARRAY 0x1023effc8 (10000 refs)>, #<ARRAY 0x11c13fdb8>]
```

### Generating heap dumps

Sheap on its own will not generate heap dumps for you. Some options for generating heap dumps:

- `ObjectSpace.dump_all(output: open("tmp/snapshot1.dump", "w"))`
- [Derailed Benchmarks](https://github.com/zombocom/derailed_benchmarks) `bundle exec derailed exec perf:heap_diff` produces 3 generations of heap dumps.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jhawthorn/sheap. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/jhawthorn/sheap/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Sheap project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/jhawthorn/sheap/blob/main/CODE_OF_CONDUCT.md).
