# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Lyra
  module Generators
    # bin/rails generate lyra:install
    #
    # Writes one migration with Lyra's own tables and the index Lyra's reads
    # need on Rails Event Store's table, and an initializer when the
    # application has none. Without the migration Lyra creates its tables the
    # first time it needs each one, as before; with it they exist beforehand,
    # appear in db/schema.rb or db/structure.sql, and the application's
    # database role needs no right to create tables.
    class InstallGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Create a migration for Lyra's own tables (and an initializer, unless one exists)."

      class_option :database, type: :string, aliases: %i[--db],
                              desc: "The database whose migrations_paths receive the migration"
      class_option :skip_initializer, type: :boolean, default: false,
                                      desc: "Do not write config/initializers/lyra.rb"

      INITIALIZER = "config/initializers/lyra.rb"

      def create_migration_file
        migration_template "create_lyra_tables.rb.tt", File.join(db_migrate_path, "create_lyra_tables.rb")
      end

      # An existing initializer is the application's: it is never replaced.
      def create_initializer
        return if options[:skip_initializer]
        return say_status(:exist, INITIALIZER, :blue) if File.exist?(File.join(destination_root, INITIALIZER))

        template "initializer.rb.tt", INITIALIZER
      end

      private

      def migration_version
        ::ActiveRecord::Migration.current_version
      end
    end
  end
end
