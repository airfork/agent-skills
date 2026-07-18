module AdversarialReview
  def self.root
    File.expand_path("../..", __dir__)
  end
end

require_relative "adversarial_review/schema"
require_relative "adversarial_review/manifest"
require_relative "adversarial_review/atomic"
require_relative "adversarial_review/state"
require_relative "adversarial_review/capabilities"
require_relative "adversarial_review/prompts"
require_relative "adversarial_review/reporting"
require_relative "adversarial_review/runner"
require_relative "adversarial_review/adapters/base"
require_relative "adversarial_review/adapters/generic"
require_relative "adversarial_review/adapters/codex"
require_relative "adversarial_review/adapters/claude"
