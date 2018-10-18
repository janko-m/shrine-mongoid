require "test_helper"
require "mongoid"

Mongoid.load!("test/mongoid.yml", :test)

describe "the monogid plugin" do
  before do
    @uploader = uploader { plugin :mongoid }

    User = Class.new {
      include Mongoid::Document
      store_in collection: "users"
      field :name, type: String
      field :avatar_data, type: String
    }
    User.include @uploader.class::Attachment.new(:avatar)

    @user = User.new
    @attacher = @user.avatar_attacher
  end

  after do
    User.destroy_all
    Object.send(:remove_const, "User")
  end

  describe "validating" do
    it "adds validation errors to the record" do
      @user.avatar_attacher.class.validate { errors << "error" }
      @user.avatar = fakeio
      refute @user.valid?
      assert_equal Hash[avatar: ["error"]], @user.errors.to_hash
    end
  end

  describe "promoting" do
    it "is triggered on save" do
      @user.update(avatar: fakeio("file1")) # insert
      refute @user.changed?
      assert_equal "store", @user.avatar.storage_key
      assert_equal "file1", @user.avatar.read

      @user.update(avatar: fakeio("file2")) # update
      refute @user.changed?
      assert_equal "store", @user.avatar.storage_key
      assert_equal "file2", @user.avatar.read
    end

    it "isn't triggered when attachment didn't change" do
      @user.update(avatar: fakeio("file"))
      attachment = @user.avatar
      @user.update(name: "Name")
      assert_equal attachment, @user.avatar
    end

    it "triggers callbacks" do
      @user.class.before_save do
        @promote_callback = true if avatar.storage_key == "store"
      end
      @user.update(avatar: fakeio)
      assert @user.instance_variable_get("@promote_callback")
    end

    it "updates only the attachment column" do
      @user.update(avatar_data: @attacher.cache!(fakeio).to_json)
      @user.class.update_all(name: "Name")
      @attacher.promote
      @user.reload
      assert_equal "store", @user.avatar.storage_key
      assert_equal "Name",  @user.name
    end

    it "bypasses validations" do
      @user.validate { errors.add(:base, "Invalid") }
      @user.avatar = fakeio
      @user.save(validate: false)
      assert_empty @user.changed_attributes
      assert_equal "store", @user.avatar.storage_key
    end
  end

  describe "replacing" do
    it "is triggered on save" do
      @user.update(avatar: fakeio)
      uploaded_file = @user.avatar
      @user.update(avatar: fakeio)
      refute uploaded_file.exists?
    end

    it "is terminated when callback chain is halted" do
      @user.update(avatar: fakeio)
      uploaded_file = @user.avatar
      @user.class.before_save { raise }
      @user.update(avatar: fakeio) rescue nil
      assert uploaded_file.exists?
    end
  end

  describe "saving" do
    it "is triggered when file is attached" do
      @user.avatar_attacher.expects(:save).twice
      @user.update(avatar: fakeio) # insert
      @user.update(avatar: fakeio) # update
    end

    it "isn't triggered when no file was attached" do
      @user.avatar_attacher.expects(:save).never
      @user.save # insert
      @user.save # update
    end
  end

  describe "destroying" do
    it "is triggered on record destroy" do
      @user.update(avatar: fakeio)
      @user.destroy
      refute @user.avatar.exists?
    end

    it "doesn't raise errors if no file is attached" do
      @user.save
      @user.destroy
    end
  end

  it "supports the attachment data field to be of type 'object'" do
    @user.class.field :avatar_data, type: Hash
    @user.update(avatar: fakeio)
    @user.avatar.exists?
  end

  it "works with backgrounding" do
    @uploader.class.plugin :backgrounding
    @attacher.class.promote { |data| self.class.promote(data) }
    @attacher.class.delete { |data| self.class.delete(data) }

    @user.update(avatar: fakeio)
    assert_equal "store", @user.reload.avatar.storage_key

    @user.destroy
    refute @user.avatar.exists?
  end

  it "returns nil when record is not found" do
    assert_nil @attacher.class.find_record(@user.class, "foo")
  end

  it "raises an appropriate exception when column is missing" do
    @user.class.include @uploader.class[:missing]
    error = assert_raises(NoMethodError) { @user.missing = fakeio }
    assert_match "undefined method `missing_data'", error.message
  end

  it "allows including attachment model to non-Sequel objects" do
    klass = Struct.new(:avatar_data)
    klass.include @uploader.class::Attachment.new(:avatar)
  end

  describe "backgrounding for embedded records" do
    before do
      @uploader = uploader do
        plugin :backgrounding
        plugin :mongoid
      end

      EmbeddedDocument = Class.new {
        include Mongoid::Document
        embedded_in :user
        field :title, type: String
        field :file_data, type: String
      }
      EmbeddedDocument.include @uploader.class::Attachment.new(:file)

      User.embeds_many :embedded_documents
      User.embeds_one :passport, class_name: "EmbeddedDocument"

      @user.save
      @embedded_document = @user.embedded_documents.create(file: fakeio)
      @embedded_document_attacher = @embedded_document.file_attacher

      @passport = @user.create_passport(file: fakeio("passport"))
      @passport_attacher = @passport.file_attacher
    end

    after do
      Object.send(:remove_const, "EmbeddedDocument")
    end

    describe "Attacher.load_record" do

      # FIXME: it's not a desirable behavior, there's no reason to initialize
      #        embedded record without parent, it will never get saved anyway
      it "initializes new instance when no parent_record given" do
        assert @embedded_document.persisted?
        loaded_record = @embedded_document_attacher.class.load_record(
          "record" => ["EmbeddedDocument", @embedded_document.id.to_s]
        )
        assert loaded_record.new_record?
        assert @embedded_document != loaded_record
      end

      it "finds embedded record when parent_record given" do
        loaded_record = @embedded_document_attacher.class.load_record(
          "record" => ["EmbeddedDocument", @embedded_document.id.to_s],
          "parent_record" => ["User", @user.id.to_s, "embedded_documents"]
        )
        assert @embedded_document == loaded_record
      end

      it "finds embedded record when parent_record given for embeds_one" do
        loaded_record = @embedded_document_attacher.class.load_record(
          "record" => ["EmbeddedDocument", @embedded_document.id.to_s],
          "parent_record" => ["User", @user.id.to_s, "passport"]
        )
        assert @passport == loaded_record
      end
    end

    describe "Attacher#dump" do
      it "includes parent_record for embedded records" do
        assert  @embedded_document_attacher.dump["parent_record"] ==
                ["User", @user.id.to_s, "embedded_documents"]
        assert  @passport_attacher.dump["parent_record"] ==
                ["User", @user.id.to_s, "passport"]
      end
    end
  end

  describe "nested attributes support" do
    before do
      Photo = Class.new {
        include Mongoid::Document
        field :title, type: String
        field :image_data, type: Hash
      }
      Photo.include @uploader.class::Attachment.new(:image)
    end

    after do
      Object.send(:remove_const, "Photo")
    end

    describe "for referenced models" do
      before do
        Photo.store_in collection: "photos"
        Photo.belongs_to :user
        User.has_many :photos, dependent: :destroy
        User.accepts_nested_attributes_for :photos, allow_destroy: true
      end

      it "stores files for nested models" do
        user = User.create!(
          name: "Jacob",
          photos_attributes: [{ image: fakeio }]
        )
        photo = user.photos.first
        assert photo.image_data["storage"] == "store"
      end
    end

    describe "for embedded models" do
      before do
        Photo.embedded_in :user
        User.embeds_many :photos
        User.accepts_nested_attributes_for :photos, allow_destroy: true
      end

      # # NOTE: Mongoid does not trigger callbacks for embedded models,
      # #   and for some reason even `cascade_callbacks` association option
      # #  does not help, so this example will fail
      # it "stores files for nested models" do
      #   user = User.create!(
      #     name: "Jacob",
      #     photos_attributes: [{ image: fakeio }]
      #   )
      #   photo = user.photos.first
      #   assert photo.image_data["storage"] == "store"
      # end

      it "stores files for nested models when manually re-saved & reloaded" do
        user = User.create!(name: "Jacob")

        user.photos_attributes =
          [{ image: fakeio, _destroy: true }, { image: fakeio }]
        user.save!

        assert user.photos.size == 1

        user.photos.each(&:save!)
        user.reload
        photo = user.photos.first
        assert photo.image_data["storage"] == "store"
      end
    end
  end
end
