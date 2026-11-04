# frozen_string_literal: true

module DeployAngel
  module Rails
    # Checkpoints the app gets without adding a line (spec §17, Silent
    # failures): mail delivered and files stored, counted from Rails' own
    # notifications. Work that quietly stops is what verdicts miss most, and
    # these two are where it most often stops. Counts only, never a
    # recipient, a filename, or a key. Off with config.derived_checkpoints =
    # false, or DEPLOYANGEL_DERIVED_CHECKPOINTS=false.
    module Checkpoints
      MAIL_DELIVERED = "rails.mail.delivered"
      FILE_STORED = "rails.storage.stored"

      def self.install
        return if @installed

        @installed = true
        ::ActiveSupport::Notifications.subscribe("deliver.action_mailer") { DeployAngel.checkpoint(MAIL_DELIVERED) }
        ::ActiveSupport::Notifications.subscribe("service_upload.active_storage") { DeployAngel.checkpoint(FILE_STORED) }
      end
    end
  end
end
