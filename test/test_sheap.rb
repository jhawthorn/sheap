# frozen_string_literal: true

require "test_helper"

class TestSheap < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Sheap::VERSION
  end

  def test_diff
    run_ruby(<<~RUBY)
      require "objspace"
      GC.start
      $arr = []
      ObjectSpace.dump_all(output: open("tmp/snapshot1.dump", "w"))
      10_000.times { $arr << [] }
      ObjectSpace.dump_all(output: open("tmp/snapshot2.dump", "w"))
      7_777.times { $arr << [] }
      ObjectSpace.dump_all(output: open("tmp/snapshot3.dump", "w"))
    RUBY

    diff = Sheap::Diff.new("tmp/snapshot1.dump", "tmp/snapshot2.dump")
    assert_includes (10000..10500), diff.objects.size

    arrays = diff.of_type("ARRAY")
    assert_includes (10000..10500), arrays.count
    assert_equal "ARRAY", arrays[0].type_str
    assert_equal "ARRAY", arrays[1].type_str
    assert_equal "ARRAY", arrays[-1].type_str
    assert_same arrays.first, arrays[0]
    assert_same arrays.last, arrays[-1]

    big_array = arrays.flat_map(&:inverse_references).tally.sort_by(&:last).last.first

    assert_equal 10_000, big_array.data["length"]
    assert_equal 10_000, big_array.references.size

    triple_diff = Sheap::Diff.new("tmp/snapshot1.dump", "tmp/snapshot2.dump" , "tmp/snapshot3.dump")
    assert_includes (10000..10500), diff.objects.size

    arrays = triple_diff.of_type("ARRAY")
    assert_includes (10000..10500), arrays.count
  end

  def test_paths_to_root
    run_ruby(<<~RUBY)
      require "objspace"
      GC.start
      $arr = []
      1337.times { $arr << [] }
      ObjectSpace.dump_all(output: open("tmp/snapshot1.dump", "w"))
    RUBY

    heap = Sheap::Heap.new("tmp/snapshot1.dump")
    assert heap.roots.size > 0

    big_array = heap.of_type("ARRAY").detect{|x| x.data["length"] == 1_337 }
    assert big_array

    small_array = big_array.references.sample

    path = heap.find_path(small_array)
    assert_equal 3, path.size
    assert path[0].root?
    assert_equal big_array, path[1]
    assert_equal small_array, path[2]
  end

  def test_compressed
    run_ruby(<<~RUBY)
      require "objspace"
      require "zlib"
      GC.start
      $arr = []
      1337.times { $arr << [] }
      Zlib::GzipWriter.open("tmp/snapshot1.dump.gz") do |f|
        f.write ObjectSpace.dump_all(output: :string)
      end
    RUBY

    heap = Sheap::Heap.new("tmp/snapshot1.dump.gz")
    assert heap.roots.size > 0

    # Check that all objects can be deserialized
    heap.objects.each(&:data)
  end

  def test_dominator_tree
    #  root_a
    #    |
    #  0x1000 <---------+
    #  /     \          |
    # 0x2000  0x3000    |
    #   \      /        |
    #    0x4000         |
    #       |           |
    #    0x5000 --------+
    heap = heap_from(
      "tmp/dominator_tree.dump",
      root("root_a", %w[0x1000]),
      object("0x1000", 10, %w[0x2000 0x3000]),
      object("0x2000", 20, %w[0x4000]),
      object("0x3000", 30, %w[0x4000]),
      object("0x4000", 40, %w[0x5000]),
      object("0x5000", 50, %w[0x1000])
    )

    tree = heap.dominator_tree

    assert_same tree.root, tree["root_a"].parent
    assert_same tree["root_a"], tree["0x1000"].parent
    assert_same tree["0x1000"], tree["0x2000"].parent
    assert_same tree["0x1000"], tree["0x3000"].parent
    assert_same tree["0x1000"], tree["0x4000"].parent
    assert_same tree["0x4000"], tree["0x5000"].parent
  end

  def test_dominator_tree_with_multiple_roots_and_retained_sizes
    #  root_a           root_b
    #  /     \             |
    # 0x1000  0x4000    0x3000
    #   |       |          |
    #   |     0x5000       |
    #   |                  |
    #   +----> 0x2000 <----+
    #
    # 0xdead  (unreachable)
    heap = heap_from(
      "tmp/dominator_tree_multiple_roots.dump",
      root("root_a", %w[0x1000 0x4000]),
      root("root_b", %w[0x3000]),
      object("0x1000", 10, %w[0x2000]),
      object("0x2000", 20),
      object("0x3000", 30, %w[0x2000]),
      object("0x4000", 40, %w[0x5000]),
      object("0x5000", 50),
      object("0xdead", 1_000)
    )

    tree = heap.dominator_tree

    assert_same tree.root, tree["0x2000"].parent
    assert_equal 10, tree["0x1000"].retained_size
    assert_equal 20, tree["0x2000"].retained_size
    assert_equal 90, tree["0x4000"].retained_size
    assert_equal 150, tree.root.retained_size
    assert_equal [100, 30, 20], tree.root.children.map(&:retained_size)
    assert_equal [90, 10], tree["root_a"].children.map(&:retained_size)
    assert_nil tree["0xdead"], "unreachable objects are not in the dominator tree"
    assert_same tree["0x4000"], tree[heap.at("0x4000")]
  end

  def test_dominator_tree_with_uppercase_root_name
    heap = heap_from(
      "tmp/dominator_tree_uppercase_root.dump",
      root("vm", %w[0x2000]),
      root("YJIT", %w[0x1000]),
      object("0x1000", 10, %w[0x3000]),
      object("0x2000", 20, %w[0x3000]),
      object("0x3000", 30)
    )

    tree = heap.dominator_tree

    assert_same tree["YJIT"], tree["0x1000"].parent
    assert_same tree.root, tree["0x3000"].parent
    assert_equal 10, tree["YJIT"].retained_size
    assert_equal 60, tree.root.retained_size
  end

  def run_ruby(code)
    system("ruby", "--disable-gems", "-e", code)
  end

  def heap_from(filename, *records)
    FileUtils.mkdir_p("tmp")
    File.write(filename, records.join("\n") << "\n")
    Sheap::Heap.new(filename)
  end

  def root(name, references)
    JSON.generate(type: "ROOT", root: name, references: references)
  end

  def object(address, memsize, references = [])
    JSON.generate(type: "OBJECT", address: address, references: references,
      memsize: memsize)
  end
end
