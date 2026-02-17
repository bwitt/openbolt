# frozen_string_literal: true

require 'spec_helper'
require 'bolt/config/transport/choria'
require 'shared_examples/transport_config'

describe Bolt::Config::Transport::Choria do
  let(:transport) { Bolt::Config::Transport::Choria }
  let(:data) { { 'choria-config' => '/etc/choria/client.conf' } }
  let(:merge_data) { { 'tmpdir' => '/path/to/tmpdir' } }

  include_examples 'transport config'
  include_examples 'filters options'

  context 'using plugins' do
    let(:plugin_data)   { { 'choria-config' => { '_plugin' => 'foo' } } }
    let(:resolved_data) { { 'choria-config' => 'foo' } }

    include_examples 'plugins'
  end

  context 'validating' do
    include_examples 'interpreters'

    it 'tty errors with wrong type' do
      data['tty'] = 'true'
      expect { transport.new(data) }.to raise_error(Bolt::ValidationError)
    end

    %w[choria-config tmpdir].each do |opt|
      it "#{opt} errors with wrong type" do
        data[opt] = 100
        expect { transport.new(data) }.to raise_error(Bolt::ValidationError)
      end
    end

    it 'connect-timeout errors with wrong type' do
      data['connect-timeout'] = 'fast'
      expect { transport.new(data) }.to raise_error(Bolt::ValidationError)
    end

    it 'cleanup errors with wrong type' do
      data['cleanup'] = 'yes'
      expect { transport.new(data) }.to raise_error(Bolt::ValidationError)
    end

    it 'collective errors with wrong type' do
      data['collective'] = 123
      expect { transport.new(data) }.to raise_error(Bolt::ValidationError)
    end

    it 'accepts valid choria-config string' do
      config = transport.new(data)
      expect(config['choria-config']).to eq('/etc/choria/client.conf')
    end

    it 'accepts valid collective string' do
      data['collective'] = 'production'
      config = transport.new(data)
      expect(config['collective']).to eq('production')
    end

    it 'accepts valid connect-timeout integer' do
      data['connect-timeout'] = 30
      config = transport.new(data)
      expect(config['connect-timeout']).to eq(30)
    end

    it 'accepts valid cleanup boolean (true)' do
      data['cleanup'] = true
      config = transport.new(data)
      expect(config['cleanup']).to eq(true)
    end

    it 'accepts valid cleanup boolean (false)' do
      data['cleanup'] = false
      config = transport.new(data)
      expect(config['cleanup']).to eq(false)
    end

    it 'accepts valid tty boolean' do
      data['tty'] = true
      config = transport.new(data)
      expect(config['tty']).to eq(true)
    end

    it 'accepts valid tmpdir string' do
      data['tmpdir'] = '/var/tmp'
      config = transport.new(data)
      expect(config['tmpdir']).to eq('/var/tmp')
    end
  end

  context 'defaults' do
    it 'sets cleanup to true by default' do
      config = transport.new({})
      expect(config['cleanup']).to eq(true)
    end

    it 'sets connect-timeout to 10 by default' do
      config = transport.new({})
      expect(config['connect-timeout']).to eq(10)
    end

    it 'does not set choria-config by default' do
      config = transport.new({})
      expect(config['choria-config']).to be_nil
    end

    it 'does not set collective by default' do
      config = transport.new({})
      expect(config['collective']).to be_nil
    end

    it 'does not set tmpdir by default' do
      config = transport.new({})
      expect(config['tmpdir']).to be_nil
    end

    it 'does not set tty by default' do
      config = transport.new({})
      expect(config['tty']).to be_nil
    end
  end

  context 'OPTIONS constant' do
    it 'includes all expected options' do
      expected = %w[choria-config cleanup collective connect-timeout interpreters tmpdir tty]
      expect(transport::OPTIONS).to match_array(expected)
    end
  end

  context 'DEFAULTS constant' do
    it 'includes expected default values' do
      expect(transport::DEFAULTS).to eq(
        'cleanup'         => true,
        'connect-timeout' => 10
      )
    end
  end

  context 'merging' do
    it 'merges options from two configs' do
      base = transport.new(data)
      merged = base.merge(merge_data)
      expect(merged['choria-config']).to eq('/etc/choria/client.conf')
      expect(merged['tmpdir']).to eq('/path/to/tmpdir')
    end

    it 'override values take precedence' do
      base = transport.new(data)
      merged = base.merge({ 'choria-config' => '/other/config.conf' })
      expect(merged['choria-config']).to eq('/other/config.conf')
    end
  end
end
