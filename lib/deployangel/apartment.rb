# frozen_string_literal: true

module DeployAngel
  # Notes each tenant ros-apartment switches to, before switching, so even a
  # tenant that turns out not to exist ("Could not find schema acme") is
  # replaced in exception messages (Redaction). The default tenant, usually
  # "public", is left alone.
  module Apartment
    module Switch
      def switch!(tenant = nil)
        begin
          DeployAngel::Redaction.note_tenant(tenant) unless tenant.nil? || tenant.to_s == default_tenant.to_s
        rescue StandardError
          nil
        end
        super
      end
    end

    def self.install
      return unless defined?(::Apartment::Tenant)

      require "apartment/adapters/abstract_adapter" unless defined?(::Apartment::Adapters::AbstractAdapter)
      adapter = ::Apartment::Adapters::AbstractAdapter
      adapter.prepend(Switch) unless adapter < Switch
    rescue LoadError, StandardError
      nil
    end
  end
end
