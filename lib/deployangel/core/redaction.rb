# frozen_string_literal: true

module DeployAngel
  # Values that name a customer of the app rather than its code, replaced in
  # exception messages before they're cleaned: the request's host and, with
  # ros-apartment, the tenants this thread last switched to. Kept per thread
  # (per fiber), where the request or job that raised ran.
  module Redaction
    HOST = :deployangel_request_host
    TENANTS = :deployangel_tenants
    MAX_TENANTS = 5
    # Shorter names would replace ordinary words.
    MIN_LENGTH = 3

    module_function

    def request_host=(host)
      Thread.current[HOST] = host
    end

    def note_tenant(tenant)
      name = tenant.to_s.strip
      return if name.length < MIN_LENGTH

      tenants = (Thread.current[TENANTS] ||= [])
      tenants.delete(name)
      tenants.unshift(name)
      tenants.pop while tenants.size > MAX_TENANTS
    end

    # [value, placeholder] pairs, longest first, so a host is replaced before
    # a tenant name inside it.
    def current
      host = Thread.current[HOST].to_s.sub(/:\d+\z/, "")
      pairs = Array(Thread.current[TENANTS]).map { |tenant| [ tenant, "<tenant>" ] }
      pairs << [ host, "<host>" ] if host.length >= MIN_LENGTH
      pairs.sort_by { |value, _| -value.length }
    end
  end
end
