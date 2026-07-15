#--
#
# Author:: Tsutomu Katsube.
# Copyright:: Copyright (c) 2025 Tsutomu Katsube. All rights reserved.
# License:: Ruby license.

require_relative "ractor-test-result"
require_relative "sub-test-result"
require_relative "test-ractor-run-context"
require_relative "test-suite-runner"

module Test
  module Unit
    class TestSuiteRactorRunner < TestSuiteRunner
      class WorkerData
        attr_reader :id, :base_directory, :test_paths, :producer_port, :test_case_descendants, :program_file
        def initialize(id, base_directory, test_paths, producer_port, test_case_descendants, program_file)
          @id = id
          @base_directory = base_directory
          @test_paths = test_paths
          @producer_port = producer_port
          @test_case_descendants = test_case_descendants
          @program_file = program_file
        end
      end

      class Worker
        def initialize(data)
          @data = data
        end

        def send(data)
          @data.producer_port.send(data.merge(consumer_port: Ractor.current.default_port))
        end

        def receive
          Ractor.current.default_port.receive
        end

        def run
          collector = Collector::Descendant.new
          suite = collector.collect(@data.base_directory, @data.test_case_descendants)

          loop do
            send(status: :ready)
            test_name = receive
            break if test_name.nil?
            test = suite.find(test_name)
            result = Test::Unit::RactorTestResult.new(@data.producer_port)
            run_context = Test::Unit::TestRunContext.new(Test::Unit::TestSuiteRunner)

            event_listener = lambda do |event_name, *args|
              send(status: :event, event_name: event_name, args: args)
            end
            if test.is_a?(Test::Unit::TestSuite)
              test_suite = test
            else
              test_suite = Test::Unit::TestSuite.new(test.class.name, test.class)
              test_suite << test
            end
            runner = Test::Unit::TestSuiteRunner.new(test_suite)
            worker_context = Test::Unit::WorkerContext.new(@data.id, run_context, result)
            runner.run(worker_context, &event_listener)
          end
          send(status: :done)

          receive
        end
      end

      class << self
        def run_all_tests(result, options)
          n_workers = TestSuiteRunner.n_workers
          test_suite = options[:test_suite]
          TestCase::DESCENDANTS.each do |test_case|
            test_case.freeze_recursive
          end

          workers = []
          begin
            producer_port = Ractor::Port.new
            n_workers.times do |i|
              worker_data = WorkerData.new(i,
                                           options[:base_directory],
                                           options[:test_paths],
                                           producer_port,
                                           TestCase::DESCENDANTS,
                                           File.expand_path($0))
              workers << Ractor.new(worker_data) do |local_worker_data|
                worker = Worker.new(local_worker_data)
                worker.run
              end
            end

            run_context = TestRactorRunContext.new(self)
            yield(run_context)
            run_context.progress_block.call(TestSuite::STARTED, test_suite.name)
            run_context.progress_block.call(TestSuite::STARTED_OBJECT, test_suite)
            run_context.parallel_unsafe_tests.each(&:call)

            until run_context.test_names.empty? do
              data = producer_port.receive
              case data[:status]
              when :ready
                test_name = run_context.test_names.shift
                break if test_name.nil?
                data[:consumer_port].send(test_name)
              when :result
                add_result(result, data)
              when :event
                emit_event(options[:event_listener], data)
              end
            end
            workers.each do |worker|
              worker.send(nil)
            end
            n_running_workers = workers.size
            while n_running_workers > 0 do
              data = producer_port.receive
              case data[:status]
              when :result
                add_result(result, data)
              when :event
                emit_event(options[:event_listener], data)
              when :done
                data[:consumer_port].send(nil)
                n_running_workers -= 1
              end
            end
          ensure
            workers.each(&:join)
          end

          run_context.progress_block.call(TestSuite::FINISHED, test_suite.name)
          run_context.progress_block.call(TestSuite::FINISHED_OBJECT, test_suite)
        end

        private
        def add_result(result, data)
          action = data[:action]
          args = data[:args]
          result.__send__(action, *args)
        end

        def emit_event(event_listener, data)
          event_name = data[:event_name]
          args = data[:args]
          event_listener.call(event_name, *args)
        end
      end

      def run(worker_context, &progress_block)
        worker_context.run_context.progress_block = progress_block
        run_tests_recursive(@test_suite, worker_context, &progress_block)
      end

      private
      def run_tests_recursive(test_suite, worker_context, &progress_block)
        run_context = worker_context.run_context
        if test_suite.have_fixture?
          run_context.test_names << test_suite.name
        else
          test_suite.tests.each do |test|
            if test.is_a?(TestSuite)
              run_tests_recursive(test, worker_context, &progress_block)
            elsif test_suite.parallel_safe?
              run_context.test_names << test.name
            else
              run_context.parallel_unsafe_tests << lambda do
                run_test(test, worker_context, &progress_block)
              end
            end
          end
        end
      end
    end
  end
end
