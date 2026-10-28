import { Database } from '@immich/sql-tools';
import { audit_action_enum, ticket_action_enum } from './enums.js';
import { AuditLogTable } from './tables/auditLog.table.js';
import { BillingStatementTable } from './tables/billingStatement.table.js';
import { BillingWebhookDeliveryTable } from './tables/billingWebhookDelivery.table.js';
import { ConnectionTable } from './tables/connection.table.js';
import { ConnectionMetricsTable } from './tables/connectionMetrics.table.js';
import { DiscordInviteBatchTable } from './tables/discordInviteBatch.table.js';
import { DiscordLinkTable } from './tables/discordLink.table.js';
import { DiscordLinkRequestTable } from './tables/discordLinkRequest.table.js';
import { DiscordTicketTable } from './tables/discordTicket.table.js';
import { RepositoryTable } from './tables/repository.table.js';
import { RepositoryMeterTable } from './tables/repositoryMeter.table.js';
import { RepositoryMeterHistoryTable } from './tables/repositoryMeterHistory.table.js';
import { RepositoryMetricsTable } from './tables/repositoryMetrics.table.js';
import { RepositoryMetricsHistoryTable } from './tables/repositoryMetricsHistory.table.js';
import { SessionTable } from './tables/session.table.js';
import { SettingsTable } from './tables/settings.table.js';
import { SupportLogSessionTable } from './tables/supportLogSession.table.js';
import { SupportLogSessionReportTable } from './tables/supportLogSessionReport.table.js';
import { TicketTable } from './tables/ticket.table.js';
import { UsageReportTable } from './tables/usageReport.table.js';
import { UserTable } from './tables/user.table.js';
import { UserAllowlistTable } from './tables/userAllowlist.table.js';
import { UserFeatureFlagOverrideTable } from './tables/userFeatureFlagOverride.table.js';

@Database({ name: 'yucca' })
export class ImmichDatabase {
  tables = [
    SessionTable,
    UserTable,
    ConnectionTable,
    ConnectionMetricsTable,
    RepositoryTable,
    RepositoryMetricsTable,
    RepositoryMetricsHistoryTable,
    RepositoryMeterTable,
    RepositoryMeterHistoryTable,
    UserAllowlistTable,
    SettingsTable,
    UserFeatureFlagOverrideTable,
    TicketTable,
    AuditLogTable,
    DiscordLinkTable,
    DiscordLinkRequestTable,
    DiscordInviteBatchTable,
    DiscordTicketTable,
    SupportLogSessionTable,
    SupportLogSessionReportTable,
    BillingStatementTable,
    BillingWebhookDeliveryTable,
    UsageReportTable,
  ];

  functions = [];

  enum = [ticket_action_enum, audit_action_enum];
}

export interface DB {
  users: UserTable;
  sessions: SessionTable;
  connections: ConnectionTable;
  connectionMetrics: ConnectionMetricsTable;
  repositories: RepositoryTable;
  repositoryMetrics: RepositoryMetricsTable;
  repositoryMetricsHistory: RepositoryMetricsHistoryTable;
  repositoryMeter: RepositoryMeterTable;
  repositoryMeterHistory: RepositoryMeterHistoryTable;
  userAllowlist: UserAllowlistTable;
  settings: SettingsTable;
  userFeatureFlagOverride: UserFeatureFlagOverrideTable;
  tickets: TicketTable;
  auditLog: AuditLogTable;
  discordLinks: DiscordLinkTable;
  discordLinkRequests: DiscordLinkRequestTable;
  discordInviteBatches: DiscordInviteBatchTable;
  discordTickets: DiscordTicketTable;
  supportLogSessions: SupportLogSessionTable;
  supportLogSessionReports: SupportLogSessionReportTable;
  billingStatements: BillingStatementTable;
  billingWebhookDeliveries: BillingWebhookDeliveryTable;
  usageReports: UsageReportTable;
}
