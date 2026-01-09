class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false, index: { unique: true }
      t.integer :age
      t.string :bio
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
