require "optparse"

parser = OptionParser.new
parser.on("--load-path=PATH") do |path|
  $LOAD_PATH << path
end
base_directory = nil
parser.on("--base-directory=PATH") do |path|
  base_directory = path
end
test_paths = parser.parse!

require_relative "../unit"
require_relative "collector/load"
require_relative "process-test-result"
Test::Unit::AutoRunner.need_auto_run = false
collector = Test::Unit::Collector::Load.new
collector.base = base_directory
suite = collector.collect(*test_paths)

data_input = IO.new(3)
data_output = IO.new(4)

loop do
  Marshal.dump({status: :ready}, data_output)
  data_output.flush
  task = Marshal.load(data_input)
  break if task.nil?
  # suite の中から対象のテストを実行して結果を返す
  pp suite.methods.sort
  pp suite.method(:initialize).source_location
  test = suite.find(task)
  result = Test::Unit::ProcessTestResult.new(data_output)
  test.run(result)
end

data_input.close
data_output.close
