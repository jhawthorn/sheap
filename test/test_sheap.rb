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

  def test_acyclic_heap
    run_ruby(<<~RUBY)
      require "objspace"
      GC.start
      $arr = []
      1337.times { $arr << [] }
      ObjectSpace.dump_all(output: open("tmp/snapshot1.dump", "w"))
    RUBY

    heap = Sheap::Heap.new("tmp/snapshot1.dump")
    aheap = Sheap::AcyclicHeap.new(heap)

    assert aheap.layers.size > 0
    assert aheap.layers.all? { |x| x.size > 0 }, "All layers should have at least one object"
    assert aheap.layers[0].all? { |obj| obj.root? } && aheap.layers[0].size == heap.roots.size, "First layer should contain all roots"

    all_objects = aheap.layers.map(&:to_a).flatten
    assert_equal all_objects.size, all_objects.uniq.size, "All objects across all layers should be unique"

    assert_equal 0, aheap.depth_of(heap.roots.first)
    assert aheap.referenced_through(heap.roots.first).size > 0
    assert aheap.referenced_through(heap.roots.first).all? { |obj| aheap.depth_of(obj) > 0 }
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

  def run_ruby(code)
    system("ruby", "--disable-gems", "-e", code)
  end
end
