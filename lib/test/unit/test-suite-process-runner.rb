#--
#
# Author:: Tsutomu Katsube.
# Copyright:: Copyright (c) 2024 Tsutomu Katsube. All rights reserved.
# License:: Ruby license.

require_relative "sub-test-result"
require_relative "test-suite-runner"
require_relative "test-process-run-context"

module Test
  module Unit
    class TestSuiteProcessRunner < TestSuiteRunner
      class << self
        class Worker
          attr_reader :main_to_worker_output, :worker_to_main_input
          def initialize(pid, main_to_worker_output, worker_to_main_input)
            @pid = pid
            @main_to_worker_output = main_to_worker_output
            @worker_to_main_input = worker_to_main_input
          end

          def receive
            Marshal.load(@worker_to_main_input)
          end

          def send(data)
            Marshal.dump(data, @main_to_worker_output)
            @main_to_worker_output.flush
          end

          def wait
            begin
              Process.waitpid(@pid)
            ensure
              begin
                @main_to_worker_output.close
              ensure
                @worker_to_main_input.close
              end
            end
          end
        end

        def run_all_tests(result, options)
          n_workers = TestSuiteRunner.n_workers

          workers = []
          begin
            n_workers.times do |i|
              load_paths = options[:load_paths]
              base_directory = options[:base_directory]
              test_paths = options[:test_paths]
              command_line = [Gem.ruby, File.join(__dir__, "process-worker.rb")]
              load_paths.each do |load_path|
                command_line << "--load-path" << load_path
              end
              unless base_directory.nil?
                command_line << "--base-directory" << base_directory
              end
              command_line.concat(test_paths)
              main_to_worker_input, main_to_worker_output = IO.pipe
              worker_to_main_input, worker_to_main_output = IO.pipe
              pid = spawn(*command_line, {3 => main_to_worker_input, 4 => worker_to_main_output})
              main_to_worker_input.close
              worker_to_main_output.close
              workers << Worker.new(pid, main_to_worker_output, worker_to_main_input)
            end

            run_context = TestProcessRunContext.new(self)
            yield(run_context)

            worker_inputs = workers.collect(&:worker_to_main_input)
            until run_context.tasks.empty? do
              readables, = IO.select(worker_inputs)
              readables.each do |worker_to_main_input|
                worker_id = worker_inputs.index(worker_to_main_input)
                worker = workers[worker_id]
                data = worker.receive
                case data[:status]
                when :ready
                  task = run_context.tasks.pop
                  break if task.nil?
                  worker.send(task)
                when :result
                  action = data[:action]
                  args = data[:args]
                  result.__send__(action, *args)
                when :event
                  event_name = data[:event_name]
                  args = data[:args]
                  options[:event_listener].call(event_name, *args)
                end
              end
            end
            workers.each do |worker|
              worker.send(nil)
            end
            until worker_inputs.empty? do
              readables, = IO.select(worker_inputs)
              readables.each do |worker_to_main_input|
                worker = workers.find do |w|
                  w.worker_to_main_input == worker_to_main_input
                end
                data = worker.receive
                case data[:status]
                when :result
                  action = data[:action]
                  args = data[:args]
                  result.__send__(action, *args)
                when :event
                  event_name = data[:event_name]
                  args = data[:args]
                  options[:event_listener].call(event_name, *args)
                when :done
                  worker_inputs.delete(worker_to_main_input)
                  worker.send(nil)
                end
              end
            end
          ensure
            workers.each do |worker|
              worker.wait
            end
          end
        end
      end

      private
      def run_tests(result, run_context: nil, &progress_block)
        @test_suite.tests.each do |test|
          if test.is_a?(TestSuite) or not @test_suite.parallel_safe?
            run_test(test, result, run_context: run_context, &progress_block)
          else
            run_context.tasks << test.name
          end
        end
      end
    end
  end
end
