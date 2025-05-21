require "optparse"

parser = OptionParser.new
parser.on("--load-path=PATH") do |path|
  $LOAD_PATH << path
end
parser.on("--base-directory=PATH") do |path|
  base_directory = path
end
test_paths = parser.parse!

require_relative "../unit"
Test::Unit::AutoRunner.need_auto_run = false
collector = Test::Unit::Collector::Load.new
collector.base = base_directory
suite = collector.collect(*test_paths)

data_input = IO.new(3)
data_output = IO.new(4)

loop do
  task = Marshal.load(data_input)
  break if task.nil?
  # suite の中から対象のテストを実行して結果を返す
  test = suite.find(task)
  result = Test::Unit::Result.new
  test.run(result)
  Marshal.dump({status: :finish}, data_output)
  data_output.flush
end
