import './bootstrap';
import Alpine from 'alpinejs';
import { registerUi, bootUi } from './ui';

window.Alpine = Alpine;
registerUi(Alpine);
Alpine.start();
bootUi(Alpine);
