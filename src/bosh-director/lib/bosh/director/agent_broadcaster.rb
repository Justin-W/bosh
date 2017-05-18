module Bosh::Director
  class AgentBroadcaster

    DEFAULT_BROADCAST_TIMEOUT = 10
    VALID_SYNC_DNS_RESPONSE = 'synced'

    def initialize(broadcast_timeout=DEFAULT_BROADCAST_TIMEOUT)
      @logger = Config.logger
      @broadcast_timeout = broadcast_timeout
    end

    def delete_arp_entries(vm_cid_to_exclude, ip_addresses)
      @logger.info("deleting arp entries for the following ip addresses: #{ip_addresses}")
      instances = filter_instances(vm_cid_to_exclude)
      instances.each do |instance|
        agent_client(instance.credentials, instance.agent_id).delete_arp_entries(ips: ip_addresses)
      end
    end

    def sync_dns(instances, blobstore_id, sha1, version)
      @logger.info("agent_broadcaster: sync_dns: sending to #{instances.length} agents #{instances.map(&:agent_id)}")

      lock = Mutex.new

      num_successful = 0
      num_unresponsive = 0
      num_failed = 0
      start_time = Time.now

      instance_to_request_id = {}
      pending = Set.new
      instances.each do |instance|
        pending.add(instance)
        instance_to_request_id[instance] = agent_client(instance.credentials, instance.agent_id).sync_dns(blobstore_id, sha1, version) do |response|
          lock.synchronize do
            if response['value'] == VALID_SYNC_DNS_RESPONSE
              num_successful += 1
              Models::AgentDnsVersion.find_or_create(agent_id: instance.agent_id).update(dns_version: version)
            else
              num_failed += 1
              @logger.error("agent_broadcaster: sync_dns[#{instance.agent_id}]: received unexpected response #{response}")
            end
            pending.delete(instance)
          end
        end
      end

      # 10s? what if we have 1000 vms?
      timeout = Timeout.new(@broadcast_timeout)

      pending_reqs = true
      while pending_reqs && !timeout.timed_out?
        lock.synchronize do
          pending_reqs = pending.any?
        end
        sleep(0.1)
      end

      lock.synchronize do
        pending.each do |instance|
          agent_client = agent_client(instance.credentials, instance.agent_id)
          agent_client.cancel_sync_dns(instance_to_request_id[instance])
          num_unresponsive += 1
          @logger.warn("agent_broadcaster: sync_dns[#{instance.agent_id}]: no response received")
        end
      end

      elapsed_time = ((Time.now - start_time) * 1000).ceil
      @logger.info("agent_broadcaster: sync_dns: attempted #{instances.length} agents in #{elapsed_time}ms (#{num_successful} successful, #{num_failed} failed, #{num_unresponsive} unresponsive)")
    end

    def filter_instances(vm_cid_to_exclude)
      Models::Instance
          .exclude(compilation: true)
          .all.select {|instance| !instance.active_vm.nil? && (instance.vm_cid != vm_cid_to_exclude) }
    end

    private

    def agent_client(instance_credentials, instance_agent_id)
      AgentClient.with_vm_credentials_and_agent_id(instance_credentials, instance_agent_id)
    end
  end
end