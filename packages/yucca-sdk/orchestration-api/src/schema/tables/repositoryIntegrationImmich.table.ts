export type ImmichRepositoryConfig = {
  dataFolders: string[];
  backupConfiguration: boolean;
  libraries: string[];
};

export class RepositoryIntegrationImmichTable {
  id!: string;

  scheduleId!: string;

  configuration!: string;
}
