package source

const (
	maxDecodeCacheBytes       = 4 << 20
	maxDecodedRepositoryBytes = 128 << 20
	ArchiveFormat             = 1
	MaxFileBytes              = 512 << 10
	MaxRepositoryBytes        = 512 << 20
	MaxRepositoryObjects      = 200000
	MaxRevisions              = 129
	MaxRevisionFiles          = 20000
	MaxReleaseCommits         = 100
	DefaultPageSize           = 100
	MaxPageSize               = 200
	DefaultLineCount          = 100
	MaxLineCount              = 200
	MaxLineBytes              = 1000
	MaxExcerptBytes           = 32000
	DefaultSearchLimit        = 30
	MaxSearchLimit            = 100
	MaxSearchQueryBytes       = 512
	MaxSearchBytes            = 32 << 20
)

type Manifest struct {
	Format         int        `json:"format"`
	GeneratedAt    string     `json:"generatedAt"`
	Head           string     `json:"head"`
	Shallow        bool       `json:"shallow"`
	Selection      string     `json:"selection"`
	Excluded       string     `json:"excluded"`
	MaxFileBytes   int        `json:"maxFileBytes"`
	DiscoveredTags int        `json:"discoveredTags"`
	OmittedRefs    []string   `json:"omittedRefs,omitempty"`
	Revisions      []Revision `json:"revisions"`
}

type Revision struct {
	Ref              string            `json:"ref"`
	Version          string            `json:"version,omitempty"`
	Commit           string            `json:"commit"`
	CommittedAt      string            `json:"committedAt"`
	Complete         bool              `json:"complete"`
	FileCount        int               `json:"fileCount"`
	ExcludedFiles    int               `json:"excludedFiles"`
	SkippedFiles     int               `json:"skippedFiles"`
	Files            map[string]string `json:"files,omitempty"`
	HistoryBase      string            `json:"historyBase,omitempty"`
	HistoryComplete  bool              `json:"historyComplete"`
	HistorySelection string            `json:"historySelection"`
	Commits          []Commit          `json:"commits,omitempty"`
}

type Commit struct {
	Hash        string `json:"hash"`
	CommittedAt string `json:"committedAt"`
	Subject     string `json:"subject"`
}

type FileList struct {
	Revision   Revision `json:"revision"`
	PathPrefix string   `json:"pathPrefix,omitempty"`
	Files      []string `json:"files"`
	Total      int      `json:"total"`
	NextOffset int      `json:"nextOffset,omitempty"`
}

type Line struct {
	Number    int    `json:"line"`
	Text      string `json:"text"`
	Truncated bool   `json:"truncated,omitempty"`
}

type FilePage struct {
	Revision   Revision `json:"revision"`
	Path       string   `json:"path"`
	TotalLines int      `json:"totalLines"`
	Lines      []Line   `json:"lines"`
	NextLine   int      `json:"nextLine,omitempty"`
}

type SearchMatch struct {
	Path string `json:"path"`
	Line
}

type SearchResult struct {
	Revision   Revision      `json:"revision"`
	Query      string        `json:"query"`
	PathPrefix string        `json:"pathPrefix,omitempty"`
	Matches    []SearchMatch `json:"matches"`
	Scanned    int           `json:"scannedFiles"`
	Truncated  bool          `json:"truncated"`
}

type Comparison struct {
	Status string    `json:"status"`
	Path   string    `json:"path"`
	From   *FilePage `json:"from,omitempty"`
	To     *FilePage `json:"to,omitempty"`
}

type ReleaseHistory struct {
	Revision   Revision `json:"revision"`
	Commits    []Commit `json:"commits"`
	Total      int      `json:"total"`
	NextOffset int      `json:"nextOffset,omitempty"`
}
