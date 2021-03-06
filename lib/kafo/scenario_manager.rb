# encoding: UTF-8
require 'kafo_wizards'

module Kafo
  class ScenarioManager
    attr_reader :config_dir, :last_scenario_link, :previous_scenario

    def initialize(config, last_scenario_link_name='last_scenario.yaml')
      @config_dir = File.file?(config) ? File.dirname(config) : config
      @last_scenario_link = File.join(config_dir, last_scenario_link_name)
      @previous_scenario = File.realpath(last_scenario_link) if File.exists?(last_scenario_link)
    end

    def available_scenarios
      # assume that *.yaml file in config_dir that has key :name is scenario definition
      @available_scenarios ||= Dir.glob(File.join(config_dir, '*.yaml')).reject { |f| f =~ /#{last_scenario_link}$/ }.inject({}) do |scns, scn_file|
        begin
          content = YAML.load_file(scn_file)
          if content.is_a?(Hash) && content.has_key?(:answer_file)
            # add scenario name for legacy configs
            content[:name] = File.basename(scn_file, '.yaml') unless content.has_key?(:name)
            scns[scn_file] = content
          end
        rescue Psych::SyntaxError => e
          warn "Warning: #{e}"
        end
        scns
      end
    end

    def list_available_scenarios
      say ::HighLine.color("Available scenarios", :info)
      available_scenarios.each do |config_file, content|
        scenario = File.basename(config_file, '.yaml')
        use = (File.expand_path(config_file) == @previous_scenario ? 'INSTALLED' : "use: --scenario #{scenario}")
        say ::HighLine.color("  #{content[:name]} ", :title)
        say "(#{use})"
        say "        " + content[:description] if !content[:description].nil? && !content[:description].empty?
      end
      say "  No available scenarios found in #{config_dir}" if available_scenarios.empty?
      KafoConfigure.exit(0)
    end

    def scenario_selection_wizard
      wizard = KafoWizards.wizard(:cli, 'Select installation scenario',
        :description => "Please select one of the pre-set installation scenarios. You can customize your setup later during the installation.")
      f = wizard.factory
      available_scenarios.keys.each do |scn|
        label = available_scenarios[scn][:name].to_s
        label += ": #{available_scenarios[scn][:description]}" if available_scenarios[scn][:description]
        wizard.entries << f.button(scn, :label => label, :default => true)
      end
      wizard.entries << f.button(:cancel, :label => 'Cancel Installation', :default => false)
      wizard
    end

    def select_scenario_interactively
      # let the user select if in interactive mode
      if (ARGV & ['--interactive', '-i']).any?
        res = scenario_selection_wizard.run
        if res == :cancel
          say 'Installation was cancelled by user'
          KafoConfigure.exit(0)
        end
        res
      end
    end

    def scenario_changed?(scenario)
      scenario = File.realpath(scenario) if File.symlink?(scenario)
      !!previous_scenario && scenario != previous_scenario
    end

    def configured?
      !!(defined?(CONFIG_DIR) && CONFIG_DIR)
    end

    def scenario_from_args
      # try scenario provided in the args via -S or --scenario
      parsed = ARGV.join(" ").match /(--scenario|-S)(\s+|[=]?)(\S+)/
      if parsed
        scenario_file = File.join(config_dir, "#{parsed[3]}.yaml")
        return scenario_file if File.exists?(scenario_file)
        KafoConfigure.logger.fatal "Scenario (#{scenario_file}) was not found, can not continue"
        KafoConfigure.exit(:unknown_scenario)
      end
    end

    def select_scenario
      scenario = scenario_from_args || previous_scenario ||
        (available_scenarios.keys.count == 1 && available_scenarios.keys.first) ||
        select_scenario_interactively
      if scenario.nil?
        fail_now("Scenario was not selected, can not continue. Use --list-scenarios to list available options.", :unknown_scenario)
      end
      scenario
    end

    def scenario_from_args
      # try scenario provided in the args via -S or --scenario
      parsed = ARGV.join(" ").match /(--scenario|-S)(\s+|[=]?)(\S+)/
      if parsed
        scenario_file = File.join(config_dir, "#{parsed[3]}.yaml")
        return scenario_file if File.exists?(scenario_file)
        fail_now("Scenario (#{scenario_file}) was not found, can not continue", :unknown_scenario)
      end
    end

    def show_scenario_diff(prev_scenario, new_scenario)
      say ::HighLine.color("Scenarios are being compared, that may take a while...", :info)
      prev_conf = load_and_setup_configuration(prev_scenario)
      new_conf = load_and_setup_configuration(new_scenario)
      print_scenario_diff(prev_conf, new_conf)
    end

    def check_scenario_change(scenario)
      if scenario_changed?(scenario)
        if ARGV.include? '--compare-scenarios'
          show_scenario_diff(@previous_scenario, scenario)
          dump_log_and_exit(0)
        else
          confirm_scenario_change(scenario)
          KafoConfigure.logger.info "Scenario #{scenario} was selected"
        end
      end
    end

    def confirm_scenario_change(new_scenario)
      unless ARGV.include?('--force')
        if (ARGV & ['--interactive', '-i']).any?
          show_scenario_diff(@previous_scenario, new_scenario)

          wizard = KafoWizards.wizard(:cli, 'Confirm installation scenario selection',
            :description => "You are trying to replace existing installation with different scenario. This may lead to unpredictable states. Please confirm that you want to proceed.")
          wizard.entries << wizard.factory.button(:proceed, :label => 'Proceed with selected installation scenario', :default => false)
          wizard.entries << wizard.factory.button(:cancel, :label => 'Cancel Installation', :default => true)
          result = wizard.run
          if result == :cancel
            say 'Installation was cancelled by user'
            dump_log_and_exit(0)
          end
        else
          message = "You are trying to replace existing installation with different scenario. This may lead to unpredictable states. " +
          "Use --force to override. You can use --compare-scenarios to see the differences"
          KafoConfigure.logger.error(message)
          dump_log_and_exit(:scenario_error)
        end
      end
    end

    def print_scenario_diff(prev_conf, new_conf)
      missing = new_conf.params_missing(prev_conf)
      changed = new_conf.params_changed(prev_conf)

      say "\n" + ::HighLine.color("Overview of modules used in the scenarios (#{prev_conf.app[:name]} -> #{new_conf.app[:name]}):", :title)
      modules = Hash.new { |h, k| h[k] = {} }
      modules = prev_conf.modules.inject(modules) { |mods, mod| mods[mod.name][:prev] = mod.enabled?; mods }
      modules = new_conf.modules.inject(modules) { |mods, mod| mods[mod.name][:new] = mod.enabled?; mods }
      printables = { "" => 'N/A', 'true' => 'ENABLED', 'false' => 'DISABLED' }
      modules.each do |mod, status|
        module_line = "%-50s: %-09s -> %s" % [mod, printables[status[:prev].to_s], printables[status[:new].to_s]]
        # highlight modules that will be disabled
        module_line = ::HighLine.color(module_line, :important) if status[:prev] == true && (status[:new] == false || status[:new].nil?)
        say module_line
      end

      say "\n" + ::HighLine.color("Defaults that will be updated with values from previous installation:", :title)
      if changed.empty?
        say "  No values will be updated from previous scenario"
      else
        changed.each { |param| say "  #{param.module.class_name}::#{param.name}: #{param.value} -> #{prev_conf.param(param.module.class_name, param.name).value}" }
      end
      say "\n" + ::HighLine.color("Values from previous installation that will be lost by scenario change:", :title)
      if missing.empty?
        say "  No values from previous installation will be lost"
      else
        missing.each { |param| say "  #{param.module.class_name}::#{param.name}: #{param.value}\n" }
      end
    end

    def link_last_scenario(config_file)
      link_path = last_scenario_link
      if last_scenario_link
        File.delete(last_scenario_link) if File.exist?(last_scenario_link)
        File.symlink(config_file, last_scenario_link)
      end
    end

    def load_and_setup_configuration(config_file)
      conf = load_configuration(config_file)
      conf.preset_defaults_from_puppet
      conf.preset_defaults_from_yaml
      conf
    end

    def load_configuration(config_file)
      Configuration.new(config_file)
    end

    private

    def fail_now(message, exit_code)
      say "ERROR: #{message}"
      KafoConfigure.logger.error message
      KafoConfigure.exit(exit_code)
    end

    def dump_log_and_exit(code)
      if Logger.buffering? && Logger.buffer.any?
        Logger.setup_verbose
        KafoConfigure.verbose = true
        if !KafoConfigure.config.nil?
          Logger.setup
          KafoConfigure.logger.info("Log was be written to #{KafoConfigure.config.log_file}")
        end
        KafoConfigure.logger.info('Logs flushed')
      end
      KafoConfigure.exit(code)
    end
  end
end
