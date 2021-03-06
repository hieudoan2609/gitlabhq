import Vue from 'vue';
import Translate from '~/vue_shared/translate';
import { GROUP_BADGE } from '~/badges/constants';
import mountBadgeSettings from '~/pages/shared/mount_badge_settings';

Vue.use(Translate);

document.addEventListener('DOMContentLoaded', () => {
  mountBadgeSettings(GROUP_BADGE);
});
