package dao

import "time"

type User struct {
	ID           string    `gorm:"type:uuid;primaryKey" json:"id"`
	Email        string    `gorm:"uniqueIndex;not null" json:"email"`
	PasswordHash string    `json:"-"`
	CreatedAt    time.Time `json:"created_at"`
}

func (User) TableName() string { return "conductor_users" }

type Session struct {
	Hash      string    `gorm:"primaryKey"`
	UserID    string    `gorm:"type:uuid;index"`
	ExpiresAt time.Time `gorm:"index"`
}

func (Session) TableName() string { return "conductor_browser_sessions" }

type Device struct {
	ID          string     `gorm:"type:uuid;primaryKey" json:"id"`
	UserID      string     `gorm:"type:uuid;index" json:"-"`
	Name        string     `json:"name"`
	TokenHash   string     `gorm:"uniqueIndex" json:"-"`
	LastSeen    time.Time  `json:"last_seen"`
	CreatedAt   time.Time  `json:"created_at"`
	RevokedAt   *time.Time `json:"revoked_at"`
	Connections []byte     `gorm:"type:jsonb" json:"-"`
}

func (Device) TableName() string { return "conductor_devices" }

type Workspace struct {
	ID       string `gorm:"type:uuid;primaryKey" json:"id"`
	DeviceID string `gorm:"type:uuid;primaryKey" json:"device_id"`
	Label    string `json:"label"`
}

func (Workspace) TableName() string { return "conductor_workspaces" }

type Snapshot struct {
	DeviceID    string    `gorm:"type:uuid;primaryKey" json:"device_id"`
	RunID       string    `gorm:"type:uuid;primaryKey" json:"run_id"`
	WorkspaceID string    `gorm:"type:uuid;index" json:"workspace_id"`
	Generation  string    `gorm:"type:uuid" json:"generation"`
	Version     uint64    `json:"version"`
	Data        []byte    `gorm:"type:jsonb" json:"-"`
	Summary     []byte    `gorm:"type:jsonb" json:"-"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func (Snapshot) TableName() string { return "conductor_snapshots" }

type Event struct {
	ID        uint64    `gorm:"primaryKey;autoIncrement" json:"id"`
	DeviceID  string    `gorm:"type:uuid;index" json:"device_id"`
	RunID     *string   `gorm:"type:uuid;index" json:"run_id,omitempty"`
	Kind      string    `json:"kind"`
	Data      []byte    `gorm:"type:jsonb" json:"-"`
	CreatedAt time.Time `json:"created_at"`
}

func (Event) TableName() string { return "conductor_events" }

type Command struct {
	ID          string     `gorm:"type:uuid;primaryKey" json:"id"`
	UserID      string     `gorm:"type:uuid;index" json:"-"`
	DeviceID    string     `gorm:"type:uuid;index" json:"device_id"`
	WorkspaceID string     `gorm:"type:uuid" json:"workspace_id"`
	Kind        string     `json:"kind"`
	Payload     []byte     `gorm:"type:jsonb" json:"-"`
	Digest      string     `json:"-"`
	Status      string     `json:"status"`
	Result      string     `json:"result"`
	CreatedAt   time.Time  `json:"created_at"`
	ExpiresAt   time.Time  `gorm:"index" json:"expires_at"`
	LeaseUntil  *time.Time `json:"-"`
}

func (Command) TableName() string { return "conductor_commands" }
