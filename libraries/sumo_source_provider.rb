require 'net/https'
require 'uri'
require 'json'

class Chef
  class Provider
    class SumoSource < Chef::Provider
      def initialize(new_resource, run_context)
        super(new_resource, run_context)
      end

      def whyrun_supported?
        true
      end

      def load_current_resource
        return if node['sumologic']['disabled']
        databag_secret = Chef::EncryptedDataBagItem.load_secret(node[:sumologic][:credentials][:secret_file])
        databag_creds = Chef::EncryptedDataBagItem.load(node[:sumologic][:credentials][:bag_name], node[:sumologic][:credentials][:item_name], databag_secret)
        @@collector ||= Sumologic::Collector.new(
          name: node.name,
          api_username: databag_creds['userID'] || node['sumologic']['userID'],
          api_password: databag_creds['password'] || node['sumologic']['password'],
          api_timeout: node['sumologic']['api_timeout'],
          query_limit: node['sumologic']['collector_query_limit']
        )

        # Does out collector exist?
        if not @@collector.exist?
          # No, bug out.
          raise Chef::Exceptions::ValidationFailed,
            "SumoLogic Collector missing from: `https://api.sumologic.com/api/v1/collectors/`"\
            "\nEither a SumoLogic Collector named: `#{node.name}` does not exist, or was not returned in collector list\n"\
            "within the limit of `#{node['sumologic']['collector_query_limit']}` collectors.\n"\
            "\nLog into the SumoLogic WebUI and verify the collector exists.\n"\
            "\nIf the collector does exist:"\
            "\n\n\tPlease increase the value of:"\
            "\n\n\t\t`default['sumologic']['collector_query_limit']`"\
            "\n\t\t\tOR"\
            "\n\t\t`node['sumologic']['collector_query_limit']`"\
            "\n\nIf the collector does not exist:"\
            "\n\n\t1. Stop the SumoCollector process:"\
            "\n\t\t`sudo /opt/SumoCollector/collector stop`"\
            "\n\n\t2. Remove the SumoCollector directory."\
            "\n\t\t`sudo rm -r /opt/SumoCollector`"\
            "\n\n\t3. Rerun chef-client."\
            "\n\t\t`sudo chef-client`\n\n"
        end

        # Is our collector in Json/Local Config mode?
        if @@collector.metadata["sourceSyncMode"] == "Json"
          # No good. We need it in UI/Cloud mode.
          Chef::Log.warn("Setting sumo collector sourceSyncMode to UI.")
          @@collector.set_ui_sync_mode
        end

        @current_resource = Chef::Resource::SumoSource.new(@new_resource.name)
        @current_resource.path(@new_resource.path)
        @current_resource.category(@new_resource.category)
        @current_resource.default_timezone(@new_resource.default_timezone)
        @current_resource.force_timezone(@new_resource.force_timezone)
        @current_resource.automatic_date_parsing(@new_resource.automatic_date_parsing)
        @current_resource.multiline_processing_enabled(@new_resource.multiline_processing_enabled)
        @current_resource.use_autoline_matching(@new_resource.use_autoline_matching)
        @current_resource.manual_prefix_regexp(@new_resource.manual_prefix_regexp)
        @current_resource.default_date_format(@new_resource.default_date_format)
        if @@collector.source_exist?(@new_resource.name) && (!node['sumologic']['disabled'])
          resource_hash = @@collector.source(@new_resource.name)
          @current_resource.path(resource_hash['pathExpression'])
          @current_resource.default_timezone(resource_hash['timeZone'])
          @current_resource.force_timezone(resource_hash['forceTimeZone'])
          @current_resource.category(resource_hash['category'])
          @current_resource.automatic_date_parsing(resource_hash['automaticDateParsing'])
          @current_resource.multiline_processing_enabled(resource_hash['multilineProcessingEnabled'])
          @current_resource.use_autoline_matching(resource_hash['useAutolineMatching'])
          @current_resource.manual_prefix_regexp(resource_hash['manualPrefixRegexp'])
          @current_resource.default_date_format(resource_hash['defaultDateFormat'])
        end
        @current_resource
      end

      def action_create
        if node['sumologic']['disabled']
          Chef::Log.debug('Skipping sumo source declaration as sumologic::disabled is set to true')
        else
          if @@collector.source_exist?(new_resource.name)
            if sumo_source_different?
              converge_by("replace #{new_resource.name} via api\n" + convergence_description) do
                @@collector.update_source!(@@collector.source(new_resource.name)['id'], new_resource.to_sumo_hash, node['sumologic']['api_timeout'])
                @@collector.refresh!
              end
              @new_resource.updated_by_last_action(true)
              Chef::Log.info("#{@new_resource} replaced sumo_source entry")
            end
          else
            converge_by("add #{new_resource.name} via sumologic api\n" + new_resource.to_sumo_hash.to_s)  do
              @@collector.add_source!(new_resource.to_sumo_hash, node['sumologic']['api_timeout'])
              @@collector.refresh!
            end
            @new_resource.updated_by_last_action(true)
            Chef::Log.info("#{@new_resource} added sumo_source entry")
          end
        end
      end

      def action_delete
        if node['sumologic']['disabled']
          Chef::Log.debug('Skipping sumo source declaration as sumologic::disabled is set to true')
        else
          if @@collector.source_exist?(@new_resource.name)
            converge_by "removing sumo source #{@new_resource.name}" do
              source_id = @@collector.source(new_resource.name)['id']
              @@collector.delete_source!(source_id)
              @@collector.refresh!
            end
            @new_resource.updated_by_last_action(true)
            Chef::Log.info("#{@new_resource} deleted sumo_source entry")
          end
        end
      end

      private

      def sumo_source_different?
        Chef::Resource::SumoSource.state_attrs.any? do |attr|
          @current_resource.send(attr) != @new_resource.send(attr)
        end
      end

      def convergence_description
        description = ''
        Chef::Resource::SumoSource.state_attrs.each do |attr|
          current_value = @current_resource.send(attr)
          new_value = @new_resource.send(attr)
          if current_value != new_value
            description << "value of #{attr} will change from '#{current_value}' to '#{new_value}'\n"
          end
        end
        description
      end
    end
  end
end
