import { ForbiddenException, NotFoundException } from '@nestjs/common';
import { TicketAction } from 'src/enum.js';

export class EmailNotAllowedException extends ForbiddenException {
  constructor() {
    super('Email is not allowed during the beta');
  }
}

export class FeatureNotEnabledException extends ForbiddenException {
  constructor(feature: string) {
    super(`Feature '${feature}' is not enabled for this account`);
  }
}

export class TicketRequiredException extends ForbiddenException {
  constructor(action: TicketAction) {
    super(`Action '${action}' has not been confirmed`);
  }
}

export class RepositoryNotFoundException extends NotFoundException {
  constructor(id: string) {
    super(`No repository with id ${id}`);
  }
}
