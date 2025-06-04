#--
#
# Author:: Tsutomu Katsube.
# Copyright:: Copyright (c) 2025 Tsutomu Katsube. All rights reserved.
# License:: Ruby license.

require_relative "test-run-context"

module Test
  module Unit
    class TestProcessRunContext < TestRunContext
      attr_reader :tasks
      def initialize(runner_class)
        super(runner_class)
        @tasks = []
      end
    end
  end
end
