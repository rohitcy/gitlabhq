# == Issuable concern
#
# Contains common functionality shared between Issues and MergeRequests
#
# Used by Issue, MergeRequest
#
module Issuable
  extend ActiveSupport::Concern
  include Participable
  include Mentionable
  include Subscribable
  include StripAttribute

  included do
    belongs_to :author, class_name: "User"
    belongs_to :assignee, class_name: "User"
    belongs_to :updated_by, class_name: "User"
    belongs_to :milestone
    has_many :notes, as: :noteable, dependent: :destroy
    has_many :label_links, as: :target, dependent: :destroy
    has_many :labels, through: :label_links
    has_many :todos, as: :target, dependent: :destroy

    validates :author, presence: true
    validates :title, presence: true, length: { within: 0..255 }

    scope :authored, ->(user) { where(author_id: user) }
    scope :assigned_to, ->(u) { where(assignee_id: u.id)}
    scope :recent, -> { reorder(id: :desc) }
    scope :assigned, -> { where("assignee_id IS NOT NULL") }
    scope :unassigned, -> { where("assignee_id IS NULL") }
    scope :of_projects, ->(ids) { where(project_id: ids) }
    scope :of_milestones, ->(ids) { where(milestone_id: ids) }
    scope :with_milestone, ->(title) { left_joins_milestones.where(milestones: { title: title }) }
    scope :opened, -> { with_state(:opened, :reopened) }
    scope :only_opened, -> { with_state(:opened) }
    scope :only_reopened, -> { with_state(:reopened) }
    scope :closed, -> { with_state(:closed) }

    scope :left_joins_milestones,    -> { joins("LEFT OUTER JOIN milestones ON #{table_name}.milestone_id = milestones.id") }
    scope :order_milestone_due_desc, -> { left_joins_milestones.reorder('milestones.due_date IS NULL, milestones.id IS NULL, milestones.due_date DESC') }
    scope :order_milestone_due_asc,  -> { left_joins_milestones.reorder('milestones.due_date IS NULL, milestones.id IS NULL, milestones.due_date ASC') }

    scope :without_label, -> { joins("LEFT OUTER JOIN label_links ON label_links.target_type = '#{name}' AND label_links.target_id = #{table_name}.id").where(label_links: { id: nil }) }
    scope :join_project, -> { joins(:project) }
    scope :references_project, -> { references(:project) }
    scope :non_archived, -> { join_project.where(projects: { archived: false }) }


    delegate :name,
             :email,
             to: :author,
             prefix: true

    delegate :name,
             :email,
             to: :assignee,
             allow_nil: true,
             prefix: true

    attr_mentionable :title, pipeline: :single_line
    attr_mentionable :description

    participant :author
    participant :assignee
    participant :notes_with_associations

    strip_attributes :title

    acts_as_paranoid

    after_save :update_assignee_cache_counts, if: :assignee_id_changed?

    def update_assignee_cache_counts
      # make sure we flush the cache for both the old *and* new assignee
      User.find(assignee_id_was).update_cache_counts if assignee_id_was
      assignee.update_cache_counts if assignee
    end
  end

  module ClassMethods
    # Searches for records with a matching title.
    #
    # This method uses ILIKE on PostgreSQL and LIKE on MySQL.
    #
    # query - The search query as a String
    #
    # Returns an ActiveRecord::Relation.
    def search(query)
      where(arel_table[:title].matches("%#{query}%"))
    end

    # Searches for records with a matching title or description.
    #
    # This method uses ILIKE on PostgreSQL and LIKE on MySQL.
    #
    # query - The search query as a String
    #
    # Returns an ActiveRecord::Relation.
    def full_search(query)
      t = arel_table
      pattern = "%#{query}%"

      where(t[:title].matches(pattern).or(t[:description].matches(pattern)))
    end

    def sort(method)
      case method.to_s
      when 'milestone_due_asc' then order_milestone_due_asc
      when 'milestone_due_desc' then order_milestone_due_desc
      when 'downvotes_desc' then order_downvotes_desc
      when 'upvotes_desc' then order_upvotes_desc
      else
        order_by(method)
      end
    end

    def order_downvotes_desc
      order_votes_desc('thumbsdown')
    end

    def order_upvotes_desc
      order_votes_desc('thumbsup')
    end

    def order_votes_desc(award_emoji_name)
      issuable_table = self.arel_table
      note_table = Note.arel_table

      join_clause = issuable_table.join(note_table, Arel::Nodes::OuterJoin).on(
        note_table[:noteable_id].eq(issuable_table[:id]).and(
          note_table[:noteable_type].eq(self.name).and(
            note_table[:is_award].eq(true).and(note_table[:note].eq(award_emoji_name))
          )
        )
      ).join_sources

      joins(join_clause).group(issuable_table[:id]).reorder("COUNT(notes.id) DESC")
    end

    def with_label(title, sort = nil)
      if title.is_a?(Array) && title.size > 1
        joins(:labels).where(labels: { title: title }).group(*grouping_columns(sort)).having("COUNT(DISTINCT labels.title) = #{title.size}")
      else
        joins(:labels).where(labels: { title: title })
      end
    end

    # Includes table keys in group by clause when sorting
    # preventing errors in postgres
    #
    # Returns an array of arel columns
    def grouping_columns(sort)
      grouping_columns = [arel_table[:id]]

      if ["milestone_due_desc", "milestone_due_asc"].include?(sort)
        milestone_table = Milestone.arel_table
        grouping_columns << milestone_table[:id]
        grouping_columns << milestone_table[:due_date]
      end

      grouping_columns
    end
  end

  def today?
    Date.today == created_at.to_date
  end

  def new?
    today? && created_at == updated_at
  end

  def is_assigned?
    !!assignee_id
  end

  def is_being_reassigned?
    assignee_id_changed?
  end

  def open?
    opened? || reopened?
  end

  def downvotes
    notes.awards.where(note: "thumbsdown").count
  end

  def upvotes
    notes.awards.where(note: "thumbsup").count
  end

  def user_notes_count
    notes.user.count
  end

  def subscribed_without_subscriptions?(user)
    participants(user).include?(user)
  end

  def to_hook_data(user)
    hook_data = {
      object_kind: self.class.name.underscore,
      user: user.hook_attrs,
      project: project.hook_attrs,
      object_attributes: hook_attrs,
      # DEPRECATED
      repository: project.hook_attrs.slice(:name, :url, :description, :homepage)
    }
    hook_data.merge!(assignee: assignee.hook_attrs) if assignee

    hook_data
  end

  def labels_array
    labels.to_a
  end

  def label_names
    labels.order('title ASC').pluck(:title)
  end

  def remove_labels
    labels.delete_all
  end

  def add_labels_by_names(label_names)
    label_names.each do |label_name|
      label = project.labels.create_with(color: Label::DEFAULT_COLOR).
        find_or_create_by(title: label_name.strip)
      self.labels << label
    end
  end

  # Convert this Issuable class name to a format usable by Ability definitions
  #
  # Examples:
  #
  #   issuable.class           # => MergeRequest
  #   issuable.to_ability_name # => "merge_request"
  def to_ability_name
    self.class.to_s.underscore
  end

  # Returns a Hash of attributes to be used for Twitter card metadata
  def card_attributes
    {
      'Author'   => author.try(:name),
      'Assignee' => assignee.try(:name)
    }
  end

  def notes_with_associations
    notes.includes(:author, :project)
  end

  def updated_tasks
    Taskable.get_updated_tasks(old_content: previous_changes['description'].first,
                               new_content: description)
  end

  ##
  # Method that checks if issuable can be moved to another project.
  #
  # Should be overridden if issuable can be moved.
  #
  def can_move?(*)
    false
  end
end
