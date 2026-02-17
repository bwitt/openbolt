# frozen_string_literal: true

require_relative '../../../bolt/error'
require_relative '../../../bolt/config/transport/base'

module Bolt
  class Config
    module Transport
      class Choria < Base
        # Options available for the choria transport
        OPTIONS = %w[
          choria-config
          cleanup
          collective
          connect-timeout
          interpreters
          tmpdir
          tty
        ].freeze

        DEFAULTS = {
          'cleanup'         => true,
          'connect-timeout' => 10
        }.freeze

        private def validate
          super

          if @config['interpreters']
            @config['interpreters'] = normalize_interpreters(@config['interpreters'])
          end
        end
      end
    end
  end
end
