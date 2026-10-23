package ticket

type Attachment struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	URL         string `json:"url"`
	ContentType string `json:"contentType,omitempty"`
	Size        int64  `json:"size"`
}

type Message struct {
	ID          string       `json:"id"`
	AuthorID    string       `json:"authorId"`
	Username    string       `json:"username"`
	Content     string       `json:"content"`
	CreatedAt   string       `json:"createdAt"`
	Attachments []Attachment `json:"attachments"`
}

type Context struct {
	TicketThreadID string    `json:"ticketThreadId"`
	DiscordUserID  string    `json:"discordUserId"`
	Closed         bool      `json:"closed"`
	Messages       []Message `json:"messages"`
}

type Activity struct {
	AuthorID  string `json:"authorId"`
	MessageID string `json:"messageId"`
}
