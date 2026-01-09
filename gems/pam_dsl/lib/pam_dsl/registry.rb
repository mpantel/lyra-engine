module PamDsl
  # Registry for storing and retrieving policies
  class Registry
    attr_reader :policies

    def initialize
      @policies = {}
    end

    # Register a policy
    def register(name, policy)
      @policies[name.to_sym] = policy
    end

    # Get a policy by name
    def get(name)
      @policies[name.to_sym]
    end

    # Get all policies
    def all
      @policies.values
    end

    # Get all policy names
    def names
      @policies.keys
    end

    # Check if policy exists
    def exists?(name)
      @policies.key?(name.to_sym)
    end

    # Remove a policy
    def remove(name)
      @policies.delete(name.to_sym)
    end

    # Clear all policies
    def clear
      @policies.clear
    end

    # Count of registered policies
    def count
      @policies.count
    end
  end
end
