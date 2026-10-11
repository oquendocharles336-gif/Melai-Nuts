import './bootstrap';
import Alpine from 'alpinejs';
import './auth';
import { registerUi, bootUi } from './ui';

window.Alpine = Alpine;
registerUi(Alpine);
Alpine.start();
bootUi(Alpine);
