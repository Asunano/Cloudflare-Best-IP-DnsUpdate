package dns

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"cfopt/internal/config"
)

// ---------------------------------------------------------------------------
// mocks
// ---------------------------------------------------------------------------

// alwaysEnabledModule 始终启用的模块（验证注册顺序 / 遍历）。
type alwaysEnabledModule struct{ id string }

func (m alwaysEnabledModule) ID() string                                   { return m.id }
func (m alwaysEnabledModule) Enabled(cfg *config.Config) bool              { return true }
func (m alwaysEnabledModule) IPSourceFiles(cfg *config.Config) []string    { return nil }
func (m alwaysEnabledModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	return &SyncResult{}, nil
}

// disabledModule 始终禁用的模块（验证 Enabled 过滤语义）。
type disabledModule struct{ id string }

func (m disabledModule) ID() string                                { return m.id }
func (m disabledModule) Enabled(cfg *config.Config) bool           { return false }
func (m disabledModule) IPSourceFiles(cfg *config.Config) []string { return nil }
func (m disabledModule) Sync(ctx context.Context, cfg *config.Config) (*SyncResult, error) {
	return &SyncResult{}, nil
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

func TestRegistry_RegisterOrderAndGet(t *testing.T) {
	reg := NewRegistry()
	a := alwaysEnabledModule{id: "a"}
	b := alwaysEnabledModule{id: "b"}
	reg.Register(a)
	reg.Register(b)

	mods := reg.Modules()
	require.Len(t, mods, 2)
	assert.Equal(t, "a", mods[0].ID())
	assert.Equal(t, "b", mods[1].ID())

	got, ok := reg.Get("b")
	require.True(t, ok)
	assert.Equal(t, "b", got.ID())

	_, ok = reg.Get("missing")
	assert.False(t, ok)
}

func TestRegistry_RegisterAll(t *testing.T) {
	reg := NewRegistry()
	reg.RegisterAll([]SyncModule{
		alwaysEnabledModule{id: "x"},
		alwaysEnabledModule{id: "y"},
		alwaysEnabledModule{id: "z"},
	})
	assert.Len(t, reg.Modules(), 3)
}

func TestRegistry_EnabledFilter(t *testing.T) {
	reg := NewRegistry()
	on := alwaysEnabledModule{id: "on"}
	off := disabledModule{id: "off"}
	reg.RegisterAll([]SyncModule{on, off})

	// Modules() 返回全部（不过滤 enabled），顺序与注册一致。
	mods := reg.Modules()
	require.Len(t, mods, 2)
	assert.Equal(t, "on", mods[0].ID())
	assert.Equal(t, "off", mods[1].ID())

	// Enabled 各自返回正确语义。
	assert.True(t, on.Enabled(&config.Config{}))
	assert.False(t, off.Enabled(&config.Config{}))
}

func TestRegistry_RegisterDedup(t *testing.T) {
	reg := NewRegistry()
	reg.Register(alwaysEnabledModule{id: "dup"})
	reg.Register(alwaysEnabledModule{id: "dup"}) // 覆盖，不重复追加顺序
	assert.Len(t, reg.Modules(), 1)
}

func TestRegistry_NilSafe(t *testing.T) {
	reg := NewRegistry()
	reg.Register(nil) // 不应 panic
	assert.Len(t, reg.Modules(), 0)
}

func TestBuiltinModules_Order(t *testing.T) {
	ids := make([]string, 0, len(BuiltinModules))
	for _, m := range BuiltinModules {
		ids = append(ids, m.ID())
	}
	assert.Equal(t, []string{"cf", "dnspod"}, ids)
}
