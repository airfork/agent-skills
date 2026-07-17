module AdversarialReview
  def self.root
    File.expand_path("../..", __dir__)
  end
end

require_relative "adversarial_review/schema"
require_relative "adversarial_review/manifest"
require_relative "adversarial_review/atomic"
require_relative "adversarial_review/state"
