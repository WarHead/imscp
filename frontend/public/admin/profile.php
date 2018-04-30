<?php
/**
 * i-MSCP - internet Multi Server Control Panel
 * Copyright (C) 2010-2018 by Laurent Declercq <l.declercq@nuxwin.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

namespace iMSCP;

use iMSCP\Authentication\AuthenticationService;
use iMSCP\Functions\View;

/**
 * Generates page
 *
 * @param TemplateEngine $tpl
 * @return void
 */
function generatePage(TemplateEngine $tpl)
{
    $stmt = execQuery('SELECT domain_created FROM admin WHERE admin_id = ?', [
        Application::getInstance()->getAuthService()->getIdentity()->getUserId()
    ]);
    $row = $stmt->fetch();
    $tpl->assign([
        'TR_ACCOUNT_SUMMARY'   => toHtml(tr('Account summary')),
        'TR_USERNAME'          => toHtml(tr('Username')),
        'USERNAME'             => toHtml(Application::getInstance()->getAuthService()->getIdentity()->getUsername()),
        'TR_ACCOUNT_TYPE'      => toHtml(tr('Account type')),
        'ACCOUNT_TYPE'         => toHtml(tr('Administrator')),
        'TR_REGISTRATION_DATE' => toHtml(tr('Registration date')),
        'REGISTRATION_DATE'    => $row['domain_created'] != 0
            ? toHtml(date(Application::getInstance()->getConfig()['DATE_FORMAT'], $row['domain_created'])) : toHtml(tr('N/A'))
    ]);
}

require_once 'application.php';

Application::getInstance()->getAuthService()->checkAuthentication(AuthenticationService::ADMIN_CHECK_AUTH_TYPE);
Application::getInstance()->getEventManager()->trigger(Events::onAdminScriptStart);

$tpl = new TemplateEngine();
$tpl->define([
    'layout'       => 'shared/layouts/ui.tpl',
    'page'         => 'shared/partials/profile.tpl',
    'page_message' => 'layout'
]);
$tpl->assign('TR_PAGE_TITLE', tr('Admin / Profile / Account Summary'));
View::generateNavigation($tpl);
generatePage($tpl);
View::generatePageMessages($tpl);
$tpl->parse('LAYOUT_CONTENT', 'page');
Application::getInstance()->getEventManager()->trigger(Events::onAdminScriptEnd, NULL, ['templateEngine' => $tpl]);
$tpl->prnt();
unsetMessages();
